// ============================================================================
// Circuito de referencia (DOCUMENTACIÓN): NO se compila en este repo.
// Requiere circom 2.x + circomlib. Ver README, sección "Pipeline off-chain".
// ============================================================================
pragma circom 2.1.6;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/mux1.circom";

// Prueba de pertenencia a un árbol Merkle Poseidon de profundidad `levels`.
template MerkleProof(levels) {
    signal input leaf;
    signal input pathElements[levels];
    signal input pathIndices[levels]; // 0 = izquierda, 1 = derecha
    signal output root;

    component h[levels];
    component mux[levels];
    signal cur[levels + 1];
    cur[0] <== leaf;
    for (var i = 0; i < levels; i++) {
        pathIndices[i] * (1 - pathIndices[i]) === 0; // booleano
        mux[i] = MultiMux1(2);
        mux[i].c[0][0] <== cur[i];
        mux[i].c[0][1] <== pathElements[i];
        mux[i].c[1][0] <== pathElements[i];
        mux[i].c[1][1] <== cur[i];
        mux[i].s <== pathIndices[i];
        h[i] = Poseidon(2);
        h[i].inputs[0] <== mux[i].out[0];
        h[i].inputs[1] <== mux[i].out[1];
        cur[i + 1] <== h[i].out;
    }
    root <== cur[levels];
}

template Vote(levels) {
    // ---- privados ----
    signal input secret;
    signal input nullifierKey;
    signal input pathElements[levels];
    signal input pathIndices[levels];
    // ---- públicos (mismo orden que ZkVoting.sol) ----
    signal input root;
    signal input nullifierHash;
    signal input proposalId;
    signal input option;

    // commitment = Poseidon(secret, nullifierKey)
    component c = Poseidon(2);
    c.inputs[0] <== secret;
    c.inputs[1] <== nullifierKey;

    // pertenece al árbol
    component mp = MerkleProof(levels);
    mp.leaf <== c.out;
    for (var i = 0; i < levels; i++) {
        mp.pathElements[i] <== pathElements[i];
        mp.pathIndices[i] <== pathIndices[i];
    }
    root === mp.root;

    // nullifier atado a la propuesta
    component n = Poseidon(2);
    n.inputs[0] <== nullifierKey;
    n.inputs[1] <== proposalId;
    nullifierHash === n.out;

    // "atar" option a la prueba (restricción cuadrática para que no se optimice)
    signal optionSq;
    optionSq <== option * option;
}

component main {public [root, nullifierHash, proposalId, option]} = Vote(20);
