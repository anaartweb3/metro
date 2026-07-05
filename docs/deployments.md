# Deployment checklist and notes

## Branches

The `main`: Must have the same code as production/live. Latest commit is always audited. It's updated in two cases:

1. A "hot deployment" by-passing current on-going changes (e.g. Hotfix, new token addition);

2. After a `develop` revision is ready for production, A `main <- develop` PR is raised and merged before deployments/upgrades.

The `develop`: Holds the on-going and unaudited changes. <u>This branch usually ahead of `main` branch.</u>. It's updated in two cases:

1. Usual development PRs;

2. After a "hot deployment", the changed files (i.e. deployment script(s) and `.json` files) are cherry-picked on top of the `develop` branch

## Audits

Audits are performed against a `develop` revision, that usually recommend changes to the code, at the these changes are merged to the `develop` usually within the ongoing changes.<br/>
Ideally, we want to "promote" `develop` changes to `main` using audit's final-report commit, but it may not be the case for some minor changes scenarios.

## Upgrader contracts

Sometimes, we need to upgrade an `*Upgrader.sol` contract, in this case, we have to use (once) a [special deployment script](./NN_upgrader.ts).

## Multisig

We have the `GNOSIS_SAFE_ADDRESS` as the prox admin and governor of all contracts, if a transaction originated by it is needed during the deployment executions, it may be executed in two ways:

1. During the execution when it is "forced" (See `DeployUpgradableFunctionProps.forceUpgrader` param). In this case, the tx will be immediately proposed and the deployment will exit.

2. If not forced, the tx is stored to a temp file and all txs will be batched and proposed at the end of deployment

Note: In both cases, the deployment script should be re-executed after the tx confirmation. The whole deployment scripts set is idempotent (which means that no task/job/tx will be executed twice) and the `hardhat-deploy` is able to catch the tx change and update the `deployments/` files according.

## Deployment steps

The following steps minimize issues during deployment (e.g. storage breaking, using wrong branch, unexpected upgrades, etc):

1. Make sure you're running scripts from the `main` branch

   It's recommended to not run deployment from PR branch, it would be better merge all changes/scripts first and then create a new deployment-only PR to merge deployment json files.

2. After having `main` branch ready, create the deployment PR and follow the steps below (Click [here](./deployment-e2e-tests.md) for more details about steps below):

   2.1. Run a forked node from a recent block

   2.2. Run the E2E tests (just to ensure that's all good with the current chain state and test)

3. Run the deployment script. That's useful because:

   3.1. To see if it'll run without errors;

   3.2. Copy and share the deployment script output for peer review to see if the transactions made are actually the expected (e.g. a simple interface change can trigger several undesired upgrades).

4. Change the E2E tests to exercise the new changes (e.g. If it's a new token addition, create deposit or mint test case for it)

5. Run the E2E test again (This round simulates the after-deployment state behavior and all tests must pass)

6. After having the second E2E run pass and the deployment output approved, we're good to go

7. Run deployment script, update releases file, verify, and push deployment json files to the PR

   Setup the env vars properly (See `.env.template` file) and run:

   ```sh
   # deploy
   $ npm run deploy -- --gasprice <gas price in wei> --network <network>

   # create release
   $ npx hardhat create-release --release <semver> --network <network>

   # verify
   $ npm run verify -- --network avalanche
   ```
