// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title AsmMarket — Marketplace de NFTs optimizado con ensamblador inline (Yul)
/// @notice Funcionalidad idéntica a `SolidityMarket` (listar, cancelar, comprar,
///         retirar comisiones), pero con las rutas calientes en assembly.
/// @dev Optimizaciones aplicadas (y por qué son seguras):
///   1. **Listado empaquetado en 1 slot**: `seller (160 bits) | price (96 bits)`.
///      uint96 alcanza para 79.228.162.514 ETH. Ahorra un SSTORE (≈20k gas) al listar.
///   2. **Slot calculado a mano**: `keccak256(nft . id)` en el scratch space
///      (0x00-0x3f), sin tocar el free memory pointer.
///   3. **Llamadas externas en assembly** (`ownerOf`, `isApprovedForAll`,
///      `getApproved`, `transferFrom`) reutilizando memoria y sin ABI-decoder.
///      Se valida `returndatasize` para no leer basura de contratos sin código.
///   4. **Errores personalizados en assembly**: `mstore(0, selector); revert(0x1c, 4)`.
///   5. **Eventos con `log4`** directamente.
///   6. Lock de reentrada en **transient storage** (EIP-1153, `tstore/tload`):
///      cuesta 100 gas en vez de ~2.9k-20k de un SSTORE.
///   Todo el assembly está marcado `memory-safe` porque solo usa el scratch space
///   o memoria por encima del free memory pointer sin moverlo.
contract AsmMarket {
    /// @notice 2,5% de comisión.
    uint256 public constant FEE_BPS = 250;
    address public immutable feeRecipient;
    /// @notice Comisiones acumuladas (slot 0).
    uint256 public accruedFees;

    // ---- selectores de errores (bytes4(keccak256("Error()"))) ----
    // NotOwner()       0x30cd7471
    // NotApproved()    0xc19f17a9
    // ZeroPrice()      0x4dfba023
    // NotListed()      0x665c1c57
    // WrongPrice()     0xf7760f25
    // TransferFailed() 0x90b8ec18
    // Reentrancy()     0xab143c06
    error NotOwner();
    error NotApproved();
    error ZeroPrice();
    error NotListed();
    error WrongPrice();
    error TransferFailed();
    error Reentrancy();

    event Listed(address indexed nft, uint256 indexed id, address indexed seller, uint256 price);
    event Cancelled(address indexed nft, uint256 indexed id);
    event Sold(address indexed nft, uint256 indexed id, address indexed buyer, uint256 price);

    // keccak256 de las firmas de eventos (topic0). Se escriben como literales porque
    // el assembly inline solo acepta constantes numéricas directas; el test
    // `test_EventTopicsMatch` verifica que coincidan con `Event.selector`.
    bytes32 private constant LISTED_T = 0x8b06cda60618abf2b2d07227f9dd63ec6349ca3269ce0eb18d49122a48362ad8;
    bytes32 private constant CANCELLED_T = 0x36ea5cd5608625e789af0282eecdb4eae1cb7c1cf6d0ec3f9a84f35be850260b;
    bytes32 private constant SOLD_T = 0x5320a7a9b87f79d5f7316ef1338262f16072733cc053d083f0cd2018928ded64;

    /// @dev Slot transitorio para el lock de reentrada.
    uint256 private constant LOCK_TSLOT = 0x6c6f636b; // "lock"
    /// @dev Prefijo para los slots de listados (evita colisión con slot 0).
    uint256 private constant LISTING_NS = 0x4c495354; // "LIST"

    constructor(address _feeRecipient) {
        feeRecipient = _feeRecipient;
    }

    // ------------------------------------------------------------------
    // Listar
    // ------------------------------------------------------------------

    /// @notice Publica `id` de `nft` a `price` wei.
    function list(address nft, uint256 id, uint96 price) external {
        assembly ("memory-safe") {
            // precio cero no permitido
            if iszero(price) {
                mstore(0x00, 0x4dfba023)
                revert(0x1c, 0x04)
            }
            let m := mload(0x40) // memoria libre como buffer temporal (no lo movemos)

            // ---- ownerOf(id) == caller ----
            mstore(m, shl(224, 0x6352211e)) // ownerOf(uint256)
            mstore(add(m, 0x04), id)
            if iszero(and(gt(returndatasize(), 0x1f), staticcall(gas(), nft, m, 0x24, 0x00, 0x20))) {
                // staticcall se evalúa primero (orden de evaluación de Yul: derecha a izquierda)
                mstore(0x00, 0x30cd7471)
                revert(0x1c, 0x04)
            }
            if iszero(eq(mload(0x00), caller())) {
                mstore(0x00, 0x30cd7471)
                revert(0x1c, 0x04)
            }

            // ---- isApprovedForAll(caller, this) || getApproved(id) == this ----
            mstore(m, shl(224, 0xe985e9c5)) // isApprovedForAll(address,address)
            mstore(add(m, 0x04), caller())
            mstore(add(m, 0x24), address())
            let approved := 0
            if and(gt(returndatasize(), 0x1f), staticcall(gas(), nft, m, 0x44, 0x00, 0x20)) {
                approved := eq(mload(0x00), 1)
            }
            if iszero(approved) {
                mstore(m, shl(224, 0x081812fc)) // getApproved(uint256)
                mstore(add(m, 0x04), id)
                if and(gt(returndatasize(), 0x1f), staticcall(gas(), nft, m, 0x24, 0x00, 0x20)) {
                    approved := eq(mload(0x00), address())
                }
            }
            if iszero(approved) {
                mstore(0x00, 0xc19f17a9)
                revert(0x1c, 0x04)
            }

            // ---- guardar listado empaquetado: seller | price << 160 ----
            mstore(0x00, nft)
            mstore(0x20, xor(id, LISTING_NS))
            let slot := keccak256(0x00, 0x40)
            sstore(slot, or(caller(), shl(160, price)))

            // ---- emitir Listed(nft, id, seller, price) ----
            mstore(0x00, price)
            log4(0x00, 0x20, LISTED_T, nft, id, caller())
        }
    }

    // ------------------------------------------------------------------
    // Cancelar
    // ------------------------------------------------------------------

    /// @notice Cancela un listado propio (devuelve el refund de SSTORE a cero).
    function cancel(address nft, uint256 id) external {
        assembly ("memory-safe") {
            mstore(0x00, nft)
            mstore(0x20, xor(id, LISTING_NS))
            let slot := keccak256(0x00, 0x40)
            let packed := sload(slot)
            // seller = 160 bits bajos
            if iszero(eq(and(packed, 0xffffffffffffffffffffffffffffffffffffffff), caller())) {
                mstore(0x00, 0x30cd7471)
                revert(0x1c, 0x04)
            }
            sstore(slot, 0)
            log3(0x00, 0x00, CANCELLED_T, nft, id)
        }
    }

    // ------------------------------------------------------------------
    // Comprar
    // ------------------------------------------------------------------

    /// @notice Compra pagando exactamente el precio. CEI + lock transitorio.
    function buy(address nft, uint256 id) external payable {
        assembly ("memory-safe") {
            // ---- lock de reentrada (transient storage) ----
            if tload(LOCK_TSLOT) {
                mstore(0x00, 0xab143c06)
                revert(0x1c, 0x04)
            }
            tstore(LOCK_TSLOT, 1)

            // ---- leer listado ----
            mstore(0x00, nft)
            mstore(0x20, xor(id, LISTING_NS))
            let slot := keccak256(0x00, 0x40)
            let packed := sload(slot)
            let seller := and(packed, 0xffffffffffffffffffffffffffffffffffffffff)
            let price := shr(160, packed)
            if iszero(seller) {
                mstore(0x00, 0x665c1c57)
                revert(0x1c, 0x04)
            }
            if iszero(eq(callvalue(), price)) {
                mstore(0x00, 0xf7760f25)
                revert(0x1c, 0x04)
            }

            // ---- efectos: borrar listado y sumar comisión ----
            sstore(slot, 0)
            // price < 2^96 y FEE_BPS = 250: el producto no puede desbordar 256 bits
            let fee := div(mul(price, FEE_BPS), 10000)
            sstore(accruedFees.slot, add(sload(accruedFees.slot), fee))

            // ---- interacción 1: transferFrom(seller, caller, id) ----
            let m := mload(0x40)
            mstore(m, shl(224, 0x23b872dd)) // transferFrom(address,address,uint256)
            mstore(add(m, 0x04), seller)
            mstore(add(m, 0x24), caller())
            mstore(add(m, 0x44), id)
            if iszero(call(gas(), nft, 0, m, 0x64, 0x00, 0x00)) {
                // propagar el motivo del revert del NFT
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
            // (si el NFT no tiene código, call devuelve éxito: lo descartamos con extcodesize)
            if iszero(extcodesize(nft)) {
                mstore(0x00, 0x90b8ec18)
                revert(0x1c, 0x04)
            }

            // ---- interacción 2: pagar al vendedor ----
            if iszero(call(gas(), seller, sub(price, fee), 0x00, 0x00, 0x00, 0x00)) {
                mstore(0x00, 0x90b8ec18)
                revert(0x1c, 0x04)
            }

            // ---- evento Sold ----
            mstore(0x00, price)
            log4(0x00, 0x20, SOLD_T, nft, id, caller())

            tstore(LOCK_TSLOT, 0)
        }
    }

    // ------------------------------------------------------------------
    // Comisiones y lectura
    // ------------------------------------------------------------------

    /// @notice Envía las comisiones acumuladas al `feeRecipient`.
    function withdrawFees() external {
        address to = feeRecipient;
        assembly ("memory-safe") {
            let f := sload(accruedFees.slot)
            sstore(accruedFees.slot, 0)
            if iszero(call(gas(), to, f, 0x00, 0x00, 0x00, 0x00)) {
                mstore(0x00, 0x90b8ec18)
                revert(0x1c, 0x04)
            }
        }
    }

    /// @notice Lee un listado (seller = 0 si no existe).
    function getListing(address nft, uint256 id) external view returns (address seller, uint256 price) {
        assembly ("memory-safe") {
            mstore(0x00, nft)
            mstore(0x20, xor(id, LISTING_NS))
            let packed := sload(keccak256(0x00, 0x40))
            seller := and(packed, 0xffffffffffffffffffffffffffffffffffffffff)
            price := shr(160, packed)
        }
    }
}
