# TrustFlowAi

TrustFlowAi is a Foundry project for `TrustFlowEscrow`, a USDC-denominated
escrow for work delivered by a configured provider/AI agent. Customers fund a
task with an ERC-20 token, review a deliverable, and either approve it or open
a dispute.

## What the contract does

- Creates tasks with a hashed brief and a work deadline.
- Holds the exact ERC-20 amount in escrow and rejects fee-on-transfer tokens.
- Lets the configured agent submit a deliverable and evidence hash.
- Supports one revision request, customer approval, and dispute resolution.
- Splits resolved payments between the provider, treasury, and customer refund.
- Allows timeout refunds, review-timeout settlement, and pull-based fund claims.
- Lets the contract owner pause new task creation and funding.
- Provides task, hash, and deadline getters for a frontend.

The provider, dispute resolver, treasury, token, and platform fee are set at
deployment and cannot be changed. The fee is in basis points (500 = 5%); the
maximum is 1,500 (15%). The contract checks that the token address contains
code, but it does not verify the token's identity or decimals. Always use a
trusted token address and pass amounts in that token's smallest units. For a
6-decimal token, 1 token is 1,000,000 units.

## Requirements and setup

- Foundry (`forge`, `cast`)
- Git with the project's submodules

For a fresh clone:

```powershell
git clone --recurse-submodules <repository-url>
cd TrustFlowAi
```

If submodules were not cloned:

```powershell
git submodule update --init --recursive
```

## Build, test, and coverage

Run from the project root:

```powershell
forge fmt --check
forge build
forge test -vv
forge coverage --report summary --exclude-tests
```

The tests use a local mock USDC token and test escrow, fees, revisions,
disputes, timeouts, refunds, token-transfer edge cases, and deployment
configuration. They do not use real funds or deploy to a public chain.
Coverage excludes the test harness and reports the contract and deployment
script. GitHub Actions runs formatting, build, tests, and coverage checks on
pushes and pull requests.

## Deploy to Avalanche Fuji

Test on Fuji before considering any mainnet deployment. The deployment script
deploys the escrow contract only; it does not deploy a token.

1. Copy the environment template:

   ```powershell
   Copy-Item .env.example .env
   ```

2. Edit `.env` and set:
   - `USDC_ADDRESS`: address of a trusted ERC-20 token already deployed on Fuji.
   - `AGENT_WALLET`: provider/agent address.
   - `RESOLVER_ADDRESS`: dispute resolver address.
   - `TREASURY_ADDRESS`: fee recipient address.
   - `FEE_BPS`: platform fee in basis points (for example, `500` for 5%).

   `.env` is ignored by Git. Do not commit private keys or other secrets.

3. Import the deployer key into Foundry's encrypted keystore. This prompts for
   the key and a keystore password:

   ```powershell
   cast wallet import trustflow-fuji --interactive
   ```

4. Fund that wallet with Fuji test AVAX for gas, then deploy:

   ```powershell
   forge script script/TrustFlowAi.s.sol:TrustFlowAiScript --rpc-url https://api.avax-test.network/ext/bc/C/rpc --chain-id 43113 --account trustflow-fuji --broadcast
   ```

Check all addresses, token details, and fee settings before broadcasting.
Mainnet deployment and explorer verification are not configured here.
