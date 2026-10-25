// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OrderBookDEX — libro de órdenes límite on-chain con matching precio-tiempo
/// @notice Un mercado BASE/QUOTE (ej. WETH/USDC). Los precios se expresan en QUOTE por 1 BASE
///         escalados a 1e18. Las órdenes que no cruzan quedan "en el libro" (maker); las que
///         cruzan se ejecutan contra el mejor precio contrario (taker), con ejecuciones parciales.
/// @dev Estructuras:
///        - Por cada nivel de precio, una cola FIFO doblemente enlazada de órdenes (prioridad
///          temporal y cancelación O(1)).
///        - Precios activos en arreglos ordenados donde el MEJOR precio está al FINAL
///          (bids ascendentes, asks descendentes) => sacar el mejor nivel es un `pop` O(1).
///        - Liquidación por patrón "pull": los fondos se acreditan en `claimable` y cada usuario
///          retira con `withdraw`. Así un maker con un token que bloquea transferencias
///          (blacklist) no puede trabar el matching de los demás (DoS).
contract OrderBookDEX is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant PRICE_SCALE = 1e18;
    /// @notice Máximo de órdenes contrarias que un taker puede consumir por llamada (acota gas).
    uint256 public constant MAX_MATCHES_CAP = 50;

    IERC20 public immutable base;
    IERC20 public immutable quote;
    /// @notice Comisión del taker en bps sobre el monto en QUOTE.
    uint256 public immutable takerFeeBps;
    address public immutable feeRecipient;

    struct Order {
        address owner;
        bool isBuy;
        uint256 price; // QUOTE por BASE * 1e18
        uint256 remaining; // BASE pendiente
        uint256 quoteEscrow; // solo compras: QUOTE retenido para pagar al ejecutarse
        uint256 prev; // enlace al anterior en el nivel (0 = ninguno)
        uint256 next; // enlace al siguiente
    }

    struct Level {
        uint256 head;
        uint256 tail;
        uint256 totalBase;
    }

    uint256 public nextOrderId = 1;
    mapping(uint256 => Order) public orders;
    /// @dev levels[isBuy][price]
    mapping(bool => mapping(uint256 => Level)) public levels;
    /// @dev Bids ascendentes (mejor = último). Asks descendentes (mejor = último).
    uint256[] internal bidPrices;
    uint256[] internal askPrices;

    /// @notice Saldos acreditados y retirables: claimable[usuario][token].
    mapping(address => mapping(address => uint256)) public claimable;

    event OrderPlaced(uint256 indexed id, address indexed owner, bool isBuy, uint256 price, uint256 amount);
    event Trade(uint256 indexed makerId, address indexed maker, address indexed taker, bool takerIsBuy, uint256 price, uint256 baseAmount, uint256 quoteAmount);
    event OrderCancelled(uint256 indexed id, uint256 refundedBase, uint256 refundedQuote);
    event Withdraw(address indexed user, address indexed token, uint256 amount);

    error ZeroAmount();
    error ZeroPrice();
    error DustOrder();
    error NotOwner();
    error NotActive();
    error LimitNotReached();

    constructor(IERC20 _base, IERC20 _quote, uint256 _takerFeeBps, address _feeRecipient) {
        require(_takerFeeBps <= 100, "fee max 1%");
        base = _base;
        quote = _quote;
        takerFeeBps = _takerFeeBps;
        feeRecipient = _feeRecipient;
    }

    // ------------------------------------------------------------------
    // Lecturas
    // ------------------------------------------------------------------

    /// @notice Mejor bid (0 si vacío).
    function bestBid() public view returns (uint256) {
        return bidPrices.length == 0 ? 0 : bidPrices[bidPrices.length - 1];
    }

    /// @notice Mejor ask (0 si vacío).
    function bestAsk() public view returns (uint256) {
        return askPrices.length == 0 ? 0 : askPrices[askPrices.length - 1];
    }

    /// @notice Profundidad (BASE) en un nivel.
    function depthAt(bool isBuy, uint256 price) external view returns (uint256) {
        return levels[isBuy][price].totalBase;
    }

    function bidLevels() external view returns (uint256[] memory) {
        return bidPrices;
    }

    function askLevels() external view returns (uint256[] memory) {
        return askPrices;
    }

    /// @notice QUOTE equivalente a `baseAmt` al precio `price`, con redondeo elegido.
    function quoteFor(uint256 baseAmt, uint256 price, bool roundUp) public pure returns (uint256) {
        return Math.mulDiv(baseAmt, price, PRICE_SCALE, roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor);
    }

    // ------------------------------------------------------------------
    // Órdenes
    // ------------------------------------------------------------------

    /// @notice Coloca una orden límite. Primero cruza contra el libro (taker) y el resto queda
    ///         como maker si `postRemainder` es true (si es false actúa como IOC/market).
    /// @param isBuy true = compra BASE pagando QUOTE.
    /// @param price Precio límite (QUOTE por BASE, 1e18).
    /// @param amount Cantidad de BASE.
    /// @param maxMatches Tope de órdenes contrarias a consumir.
    /// @param postRemainder Si el remanente queda en el libro.
    /// @return id Id de la orden en reposo (0 si no quedó remanente).
    /// @return filled BASE ejecutado como taker.
    function placeLimitOrder(bool isBuy, uint256 price, uint256 amount, uint256 maxMatches, bool postRemainder)
        external
        nonReentrant
        returns (uint256 id, uint256 filled)
    {
        if (amount == 0) revert ZeroAmount();
        if (price == 0) revert ZeroPrice();
        if (quoteFor(amount, price, false) == 0) revert DustOrder();
        if (maxMatches > MAX_MATCHES_CAP) maxMatches = MAX_MATCHES_CAP;

        uint256 quoteMoved; // QUOTE pagado (compra) o recibido (venta) como taker
        (filled, quoteMoved) = _match(isBuy, price, amount, maxMatches);
        uint256 fee = Math.mulDiv(quoteMoved, takerFeeBps, 10_000, Math.Rounding.Ceil);
        claimable[feeRecipient][address(quote)] += fee;

        uint256 rest = amount - filled;
        bool post = postRemainder && rest > 0 && quoteFor(rest, price, false) > 0;
        uint256 restEscrow = post && isBuy ? quoteFor(rest, price, true) : 0;

        if (isBuy) {
            // Comprador: paga QUOTE de lo ejecutado + comisión + escrow del remanente.
            quote.safeTransferFrom(msg.sender, address(this), quoteMoved + fee + restEscrow);
            claimable[msg.sender][address(base)] += filled;
        } else {
            // Vendedor: entrega BASE de lo ejecutado + remanente; cobra QUOTE menos comisión.
            base.safeTransferFrom(msg.sender, address(this), filled + (post ? rest : 0));
            claimable[msg.sender][address(quote)] += quoteMoved - fee;
        }

        if (post) id = _rest(isBuy, price, rest, restEscrow);
    }

    /// @notice Cancela una orden en reposo y acredita lo no ejecutado.
    function cancel(uint256 id) external nonReentrant {
        Order storage o = orders[id];
        if (o.owner != msg.sender) revert NotOwner();
        if (o.remaining == 0) revert NotActive();
        uint256 rb = o.isBuy ? 0 : o.remaining;
        uint256 rq = o.isBuy ? o.quoteEscrow : 0;
        _unlink(id);
        if (rb > 0) claimable[msg.sender][address(base)] += rb;
        if (rq > 0) claimable[msg.sender][address(quote)] += rq;
        emit OrderCancelled(id, rb, rq);
    }

    /// @notice Retira saldo acreditado de `token`.
    function withdraw(IERC20 token) external nonReentrant {
        uint256 amt = claimable[msg.sender][address(token)];
        claimable[msg.sender][address(token)] = 0;
        token.safeTransfer(msg.sender, amt);
        emit Withdraw(msg.sender, address(token), amt);
    }

    // ------------------------------------------------------------------
    // Internos
    // ------------------------------------------------------------------

    /// @dev Cruza contra el lado contrario mientras haya precio compatible.
    ///      La ejecución ocurre al precio del MAKER (el taker recibe la mejora de precio).
    function _match(bool isBuy, uint256 limit, uint256 amount, uint256 maxMatches)
        internal
        returns (uint256 filled, uint256 quoteMoved)
    {
        uint256[] storage book = isBuy ? askPrices : bidPrices;
        uint256 matches;
        while (filled < amount && book.length > 0 && matches < maxMatches) {
            uint256 p = book[book.length - 1];
            // Compra cruza si ask <= límite; venta cruza si bid >= límite.
            if (isBuy ? p > limit : p < limit) break;
            Level storage lvl = levels[!isBuy][p];
            uint256 makerId = lvl.head;
            Order storage m = orders[makerId];

            uint256 fill = Math.min(amount - filled, m.remaining);
            uint256 q;
            if (isBuy) {
                // Taker compra a un maker vendedor: paga redondeando hacia arriba (protege al maker).
                q = quoteFor(fill, p, true);
                claimable[m.owner][address(quote)] += q;
            } else {
                // Taker vende a un maker comprador: se paga desde el escrow del maker, hacia abajo.
                q = quoteFor(fill, p, false);
                m.quoteEscrow -= q;
                claimable[m.owner][address(base)] += fill;
            }
            m.remaining -= fill;
            lvl.totalBase -= fill;
            filled += fill;
            quoteMoved += q;
            matches++;
            emit Trade(makerId, m.owner, msg.sender, isBuy, p, fill, q);

            if (m.remaining == 0) {
                // Orden del maker completada: devolvemos el polvo de escrow por redondeo.
                if (m.quoteEscrow > 0) {
                    claimable[m.owner][address(quote)] += m.quoteEscrow;
                    m.quoteEscrow = 0;
                }
                _unlink(makerId);
            }
        }
    }

    /// @dev Agrega una orden en reposo al final de la cola de su nivel.
    function _rest(bool isBuy, uint256 price, uint256 amount, uint256 escrow) internal returns (uint256 id) {
        id = nextOrderId++;
        Level storage lvl = levels[isBuy][price];
        orders[id] = Order(msg.sender, isBuy, price, amount, escrow, lvl.tail, 0);
        if (lvl.tail == 0) {
            lvl.head = id;
            _insertPrice(isBuy, price);
        } else {
            orders[lvl.tail].next = id;
        }
        lvl.tail = id;
        lvl.totalBase += amount;
        emit OrderPlaced(id, msg.sender, isBuy, price, amount);
    }

    /// @dev Quita una orden de su nivel (O(1)) y borra el nivel si queda vacío.
    function _unlink(uint256 id) internal {
        Order storage o = orders[id];
        Level storage lvl = levels[o.isBuy][o.price];
        lvl.totalBase -= o.remaining;
        if (o.prev != 0) orders[o.prev].next = o.next;
        else lvl.head = o.next;
        if (o.next != 0) orders[o.next].prev = o.prev;
        else lvl.tail = o.prev;
        o.remaining = 0;
        o.quoteEscrow = 0;
        if (lvl.head == 0) _removePrice(o.isBuy, o.price);
    }

    /// @dev Inserta un precio manteniendo el orden (mejor al final).
    function _insertPrice(bool isBuy, uint256 price) internal {
        uint256[] storage arr = isBuy ? bidPrices : askPrices;
        arr.push(price);
        uint256 i = arr.length - 1;
        // bids ascendentes: desplazamos mientras el anterior sea mayor.
        // asks descendentes: desplazamos mientras el anterior sea menor.
        while (i > 0 && (isBuy ? arr[i - 1] > price : arr[i - 1] < price)) {
            arr[i] = arr[i - 1];
            i--;
        }
        arr[i] = price;
    }

    /// @dev Elimina un precio (caso típico: es el último => O(1)).
    function _removePrice(bool isBuy, uint256 price) internal {
        uint256[] storage arr = isBuy ? bidPrices : askPrices;
        uint256 n = arr.length;
        for (uint256 i = n; i > 0; i--) {
            if (arr[i - 1] == price) {
                for (uint256 j = i - 1; j + 1 < n; j++) {
                    arr[j] = arr[j + 1];
                }
                arr.pop();
                return;
            }
        }
    }
}
