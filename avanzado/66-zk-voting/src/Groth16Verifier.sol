// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Groth16Verifier — Verificador Groth16 genérico sobre BN254 (alt_bn128)
/// @notice Verifica pruebas zk-SNARK Groth16 usando los precompilados de Ethereum:
///         - 0x06 `ecAdd`  (EIP-196): suma de puntos en G1
///         - 0x07 `ecMul`  (EIP-196): multiplicación escalar en G1
///         - 0x08 `ecPairing` (EIP-197): chequeo de producto de emparejamientos
/// @dev La clave de verificación (VK) se pasa en el constructor, así el mismo contrato
///      sirve para cualquier circuito (snarkjs/circom genera verificadores con la VK
///      "hardcodeada"; acá la guardamos en storage para poder testear con una VK de juguete).
///
///      Ecuación de Groth16:
///          e(A, B) == e(α, β) · e(vk_x, γ) · e(C, δ)
///      con vk_x = IC[0] + Σ input[i] · IC[i+1].
///      Se reescribe como un único chequeo de pairing:
///          e(−A, B) · e(α, β) · e(vk_x, γ) · e(C, δ) == 1
contract Groth16Verifier {
    /// @notice Orden del grupo (campo escalar) de BN254. Los inputs públicos deben ser < R.
    uint256 public constant R = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
    /// @notice Primo del campo base de BN254 (coordenadas de puntos).
    uint256 public constant Q = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    /// @notice Punto en G1 (x, y).
    struct G1 {
        uint256 x;
        uint256 y;
    }

    /// @notice Punto en G2: coordenadas en Fp2, codificadas [imaginaria, real] como espera EIP-197.
    struct G2 {
        uint256[2] x;
        uint256[2] y;
    }

    G1 public alpha;
    G2 internal beta;
    G2 internal gamma;
    G2 internal delta;
    /// @notice IC[0..n]: un punto por input público, más el término constante.
    G1[] internal ic;

    error InputNotInField();
    error WrongInputLength();
    error PrecompileFailed();

    constructor(G1 memory _alpha, G2 memory _beta, G2 memory _gamma, G2 memory _delta, G1[] memory _ic) {
        alpha = _alpha;
        beta = _beta;
        gamma = _gamma;
        delta = _delta;
        for (uint256 i = 0; i < _ic.length; i++) ic.push(_ic[i]);
    }

    /// @notice Cantidad de inputs públicos que espera el circuito.
    function numInputs() external view returns (uint256) {
        return ic.length - 1;
    }

    /// @notice Verifica una prueba Groth16.
    /// @param a Punto A (G1)
    /// @param b Punto B (G2) en formato [[x_im, x_re], [y_im, y_re]]
    /// @param c Punto C (G1)
    /// @param input Inputs públicos (cada uno < R)
    /// @return true si la prueba es válida
    function verifyProof(uint256[2] calldata a, uint256[2][2] calldata b, uint256[2] calldata c, uint256[] calldata input)
        external
        view
        returns (bool)
    {
        if (input.length + 1 != ic.length) revert WrongInputLength();

        // ---- 1. vk_x = IC[0] + Σ input[i]·IC[i+1] ----
        G1 memory vkx = ic[0];
        for (uint256 i = 0; i < input.length; i++) {
            // Sin este chequeo, input e input+R darían la misma prueba (maleabilidad)
            if (input[i] >= R) revert InputNotInField();
            vkx = _add(vkx, _mul(ic[i + 1], input[i]));
        }

        // ---- 2. Armar los 4 pares para el pairing ----
        // Cada par ocupa 6 palabras: G1 (x, y) + G2 (x_im, x_re, y_im, y_re)
        uint256[24] memory p;
        // par 1: (−A, B). Negar en G1: (x, Q − y). Si y == 0 la negación es (x, 0).
        p[0] = a[0];
        p[1] = a[1] == 0 ? 0 : Q - (a[1] % Q);
        p[2] = b[0][0];
        p[3] = b[0][1];
        p[4] = b[1][0];
        p[5] = b[1][1];
        // par 2: (α, β)
        p[6] = alpha.x;
        p[7] = alpha.y;
        p[8] = beta.x[0];
        p[9] = beta.x[1];
        p[10] = beta.y[0];
        p[11] = beta.y[1];
        // par 3: (vk_x, γ)
        p[12] = vkx.x;
        p[13] = vkx.y;
        p[14] = gamma.x[0];
        p[15] = gamma.x[1];
        p[16] = gamma.y[0];
        p[17] = gamma.y[1];
        // par 4: (C, δ)
        p[18] = c[0];
        p[19] = c[1];
        p[20] = delta.x[0];
        p[21] = delta.x[1];
        p[22] = delta.y[0];
        p[23] = delta.y[1];

        // ---- 3. Pairing check (precompilado 0x08) ----
        uint256[1] memory out;
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gas(), 0x08, p, 768, out, 0x20)
        }
        // Si los puntos no están en la curva el precompilado falla: la prueba es inválida.
        if (!ok) return false;
        return out[0] == 1;
    }

    // ------------------------------------------------------------------
    // Helpers de curva (precompilados 0x06 y 0x07)
    // ------------------------------------------------------------------

    function _add(G1 memory p1, G1 memory p2) internal view returns (G1 memory r) {
        uint256[4] memory inp = [p1.x, p1.y, p2.x, p2.y];
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gas(), 0x06, inp, 0x80, r, 0x40)
        }
        if (!ok) revert PrecompileFailed();
    }

    function _mul(G1 memory p1, uint256 s) internal view returns (G1 memory r) {
        uint256[3] memory inp = [p1.x, p1.y, s];
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gas(), 0x07, inp, 0x60, r, 0x40)
        }
        if (!ok) revert PrecompileFailed();
    }
}
