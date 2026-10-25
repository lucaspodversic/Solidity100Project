# Solidity100Project

# **100 solidity proyect**


Lista de **100 proyectos Solidity** estructurados por categorías y niveles de dificultad. El objetivo es demostrar no solo que sabes escribir código, sino que comprendes la economía de los contratos, la seguridad y la arquitectura de protocolos reales, que es exactamente lo que buscan las empresas del sector.

### 🏦 DeFi (Finanzas Descentralizadas)

*Fuente principal: Hashtag Web3 (60 ideas DeFi)*

**AMM y DEX**

1. **Constant Product AMM Clone** (Intermedio): Réplica de Uniswap V2 con provisión de liquidez, swaps y recolección de comisiones.
2. **Concentrated Liquidity DEX** (Avanzado): Implementación estilo Uniswap V3 con rangos de precios y gestión de posiciones.
3. **Multi-hop Router** (Avanzado): Router que encuentra la ruta óptima de swap entre múltiples pools.
4. **Limit Order Book DEX** (Avanzado): Libro de órdenes on-chain con motor de matching y ejecuciones parciales.
5. **Stableswap Implementation** (Avanzado): Invariante StableSwap estilo Curve para swaps de baja volatilidad.
6. **TWAP Oracle from DEX** (Intermedio): Oráculo de precio promedio ponderado por tiempo usando datos de tu propio AMM.
7. **Impermanent Loss Calculator** (Principiante): Calculadora interactiva de pérdida impermanente.
8. **Gas-Optimized Multicall** (Intermedio): Contrato para agrupar operaciones DeFi minimizando gas.

**Préstamos y Crédito**

9. **Simple Lending Protocol** (Intermedio): Depósitos, préstamos, acumulación de intereses y liquidaciones.
10. **Isolated Lending Markets** (Avanzado): Mercados de préstamo aislados estilo Silo para cada par de activos.
11. **Interest Rate Model Simulator** (Intermedio): Simulador de curvas de tasas de interés y su efecto en el uso.
12. **Liquidation Bot** (Avanzado): Bot que monitorea protocolos y ejecuta liquidaciones rentables.
13. **Credit Delegation System** (Avanzado): Delegación de poder de préstamo estilo Aave.
14. **Health Factor Dashboard** (Intermedio): Dashboard para monitorear posiciones y alertar sobre riesgo de liquidación.
15. **Flash Loan Executor** (Avanzado): Ejecutor modular de flash loans que encadena operaciones DeFi.
16. **Position Manager** (Avanzado): Contrato que gestiona posiciones multi-protocolo con rebalanceo en un clic.
17. **DeFi Position Simulator** (Intermedio): Simulador de cómo cambian las posiciones bajo distintos escenarios de mercado.

**Vaults y Yield**

18. **ERC-4626 Tokenized Vault** (Intermedio): Implementación del estándar de vaults tokenizados.
19. **Auto-compounding Vault** (Intermedio): Vault que cosecha y compone rendimientos automáticamente.
20. **Multi-strategy Vault** (Avanzado): Vault estilo Yearn que asigna fondos entre varias estrategias según el APY.
21. **Yield Aggregator Dashboard** (Intermedio): Dashboard que compara rendimientos, TVL y riesgo entre protocolos.
22. **Recursive Lending Strategy** (Avanzado): Estrategia que usa préstamos recursivos para apalancar posiciones de yield.
23. **Vault Share Accounting** (Intermedio): Análisis profundo de ataques de donación y redondeo en el cálculo de shares.
24. **Delta-Neutral Vault** (Avanzado): Vault que mantiene posiciones delta-neutral mientras genera yield por funding rates.

**Derivados y Sintéticos**

25. **Perpetual Futures Contract** (Avanzado): Contrato de futuros perpetuos simplificado con funding rates y liquidaciones.
26. **Options Protocol** (Avanzado): Protocolo básico de opciones call/put con strikes y expiraciones.
27. **Synthetic Asset Minter** (Avanzado): Protocolo que acuña activos sintéticos colateralizados con mecanismo de estabilidad.
28. **Prediction Market** (Intermedio/Avanzado): Mercado de predicciones binarias con precios basados en probabilidad implícita.
29. **Funding Rate Arbitrage Bot** (Avanzado): Bot que identifica oportunidades de arbitraje de funding entre venues.

### 🖼️ NFT y Tokenización

30. **Simple NFT** (Principiante): Ciclo completo de compilación, despliegue y frontend para un NFT.
31. **NFT Marketplace** (Intermedio/Avanzado): Marketplace descentralizado con listados ERC721, comisiones y protección contra reentrancy.
32. **On-chain NFT** (Avanzado): NFT cuyos metadatos (SVG) se generan y almacenan completamente on-chain, sin IPFS.
33. **NFT with ERC2981 Royalties** (Intermedio): Marketplace que implementa el estándar de royalties ERC2981.
34. **Lazy Minting NFT Marketplace** (Avanzado): Marketplace con acuñación perezosa y verificación de firmas.
35. **Cross-chain NFT Marketplace** (Avanzado): Marketplace de NFTs con despliegue multi-cadena y optimización de gas.
36. **NFT Liquidity Platform** (Avanzado): Plataforma que combina pools estilo AMM con marketplace tradicional de NFTs.
37. **Dynamic NFT** (Intermedio): NFT cuyos atributos cambian según datos on-chain o externos (Chainlink).
38. **NFT Swap Contract** (Principiante/Intermedio): Contrato para intercambiar NFTs de forma trustless.
39. **Time-unlocked ERC20 (Vesting)** (Principiante): Contrato de bloqueo temporal de tokens para vesting.

### 🏛️ DAO y Gobernanza

40. **Basic DAO Voting System** (Principiante): Sistema de votación DAO sin token, con propuestas y ejecución.
41. **DAO with Governance Token** (Intermedio): DAO completo con token ERC20, delegación y gobernanza on-chain.
42. **Quadratic Voting DAO** (Avanzado): Framework DAO que implementa votación cuadrática y delegación.
43. **Timelock Governance** (Intermedio): Mecanismo de timelock para ejecución segura de propuestas.
44. **Fractional Ownership DAO** (Avanzado): DAO que gestiona la propiedad fraccionada de NFTs.
45. **DAO-based Donation System** (Intermedio): Sistema de donaciones donde los donantes votan por la priorización de proyectos.
46. **DAO-controlled Vault** (Avanzado): Vault DeFi controlado por una DAO que gestiona parámetros y upgrades.
47. **Governance Dashboard** (Intermedio): Frontend para visualizar propuestas, votos y delegaciones de una DAO.

### 🔐 Seguridad y Auditoría

*Esta sección demuestra pensamiento adversarial, muy valorado por las empresas.*

48. **Dice Game Exploit** (Principiante): Análisis de un contrato vulnerable por aleatoriedad débil y escritura de un contrato atacante.
49. **Reentrancy Attack & Defense** (Intermedio): Implementación de un ataque de reentrancy clásico y su mitigación con Checks-Effects-Interactions.
50. **Read-only Reentrancy PoC** (Avanzado): Proof of concept de reentrancy de solo lectura (estilo Curve).
51. **Oracle Manipulation PoC** (Avanzado): Demostración de manipulación de oráculos vía flash loans y defensas con TWAP.
52. **MEV Sandwich Attack Simulation** (Avanzado): Simulación de un ataque sándwich y estrategias de resistencia MEV.
53. **Smart Contract Audit Report** (Intermedio/Avanzado): Auditoría completa de un contrato DeFi (VaultManager o LendingPool), con hallazgos y parches.
54. **Vulnerable Token Audit** (Intermedio): Auditoría de un token ERC20 con vulnerabilidades intencionadas (front-running, aleatoriedad débil).
55. **Access Control Audit** (Intermedio): Revisión de roles, permisos y boundaries en contratos con proxies.
56. **Proxy Storage Layout Audit** (Avanzado): Análisis de riesgos de inicialización y colisiones de storage en proxies.
57. **Signature Replay Attack PoC** (Avanzado): Demostración de bugs de replay en firmas y permits.

### ⚙️ Infraestructura y Herramientas

58. **Multisig Wallet** (Intermedio): Billetera multifirma con umbral configurable y ejecución de transacciones.
59. **Factory Pattern Deployment** (Intermedio): Uso del patrón Factory para despliegue dinámico de contratos.
60. **UUPS Proxy Upgradeable Contract** (Avanzado): Implementación de contratos actualizables usando el patrón UUPS.
61. **Gas Estimation Experiment** (Principiante/Intermedio): Contrato para comparar costos de gas entre structs, mappings y arrays.
62. **Protocol Revenue Tracker** (Intermedio): Dashboard que rastrea ingresos por comisiones en protocolos DeFi.
63. **Smart Contract Wallet** (Intermedio): Billetera inteligente con autenticación vía `msg.sender`.
64. **Account Abstraction (ERC-4337) Paymaster** (Avanzado): Sistema de patrocinio de gas con Paymaster y session keys.
65. **Inline Assembly NFT Marketplace** (Avanzado): Marketplace de NFTs usando ensamblador inline para optimización extrema de gas.

### 🧪 Avanzado / Especializado

*Proyectos que pocos candidatos junior tienen en su portafolio.*

66. **ZK Voting** (Avanzado): Votación con privacidad usando circuitos Noir y verificador en Solidity.
67. **Stablecoin Protocol** (Avanzado): Stablecoin colateralizada con ratios, incentivos de liquidación y tasas dinámicas.
68. **Over-Collateralized Lending** (Avanzado): Mercado monetario con liquidaciones y flash loans.
69. **Oracle Architecture Comparison** (Avanzado): Implementación de tres arquitecturas de oráculos (whitelist, staking, optimista) y análisis de trade-offs.
70. **Cross-Chain Rebase Token** (Avanzado): Token con mecánica de rebase que opera en múltiples cadenas.
71. **Tokenized Real Estate** (Avanzado): Plataforma de tokenización de bienes raíces con NFTs y DAO.
72. **AI Smart Contract Auditor Marketplace** (Avanzado): Mercado de auditorías con certificados como NFTs soulbound.
73. **AgentCred (Identity & Reputation)** (Avanzado): Sistema de identidad y reputación on-chain usando ERC-721 y TEE.
74. **LeaseNFT Protocol** (Avanzado): Protocolo que transforma pagos de alquiler en activos productivos (NFT + Vault).
75. **VortexAI (AI Fund Manager)** (Avanzado): Agente de IA que gestiona liquidez en un par volátil dentro de una DAO.

### 🧩 Fundamentos y Patrones (Proyectos de apoyo)

*Proyectos más pequeños que sirven para demostrar dominio de patrones específicos.*

76. **Crowdfunding** (Principiante): Máquina de estados con manejo de ETH y plazos.
77. **Token Vendor** (Principiante): Compra/venta de tokens ERC20 con transferencias seguro contrato-a-contrato.
78. **Simple Lottery** (Principiante): Lotería on-chain con selección pseudoaleatoria.
79. **English Auction** (Principiante/Intermedio): Subasta inglesa con pujas y extensión de tiempo.
80. **Time Lock Contract** (Principiante): Bloqueo de funciones usando `block.timestamp`.
81. **Whitelist Access Control** (Principiante): Restricción de funciones a direcciones en lista blanca.
82. **Pause/Unpause Functionality** (Principiante): Mecanismo de pausa de emergencia para contratos.
83. **Role Management System** (Intermedio): Asignación manual de roles (admin, minter, pauser).
84. **Custom Errors and Reverts** (Principiante): Uso de errores personalizados para ahorrar gas.
85. **String Comparison in Solidity** (Principiante): Comparación de strings y hashing con Keccak256.
86. **Struct vs Mapping Gas Cost** (Principiante): Comparativa de costos de almacenamiento.
87. **Interface Implementation** (Principiante): Creación y uso de interfaces para interacción entre contratos.
88. **Inheritance Contract** (Principiante): Uso de herencia para modularizar lógica.
89. **Self-destruct Contract** (Principiante): Contrato que se autodestruye y envía fondos.
90. **Fallback & Receive Functions** (Principiante): Manejo de ETH entrante y funciones fallback.
91. **Event Logging & Frontend Listeners** (Principiante): Emisión de eventos y escucha desde el frontend.
92. **IPFS Hash Storage** (Principiante): Almacenamiento de hashes de IPFS en un contrato.
93. **Merkle Tree Whitelist** (Intermedio): Uso de árboles de Merkle para verificación eficiente de listas blancas.
94. **Multi-sig Transaction Execution** (Intermedio): Ejecución de transacciones que requieren múltiples aprobaciones.
95. **Upgradeable Token** (Avanzado): Token ERC20 con mecánica de upgrade vía proxy.
96. **Gasless Meta-Transactions (EIP-2771)** (Avanzado): Implementación de transacciones sin gas para usuarios.
97. **Dutch Auction** (Intermedio): Subasta holandesa con precio decreciente en el tiempo.
98. **Snapshot Token** (Avanzado): Token que toma snapshots de balances para votaciones de gobernanza.
99. **Streaming Payments (Sablier-style)** (Avanzado): Pagos continuos por segundo a un beneficiario.
100. **Decentralized Raffle with Chainlink VRF** (Intermedio): Rifa descentralizada con aleatoriedad verificable.

