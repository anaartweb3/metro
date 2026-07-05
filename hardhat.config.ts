import {HardhatUserConfig} from 'hardhat/types'
import '@nomicfoundation/hardhat-toolbox'
import 'hardhat-deploy'
import 'hardhat-log-remover'
import 'hardhat-contract-sizer'
import 'hardhat-spdx-license-identifier'
import './tasks/create-release'
import './tasks/impersonate-deployer'
import dotenv from 'dotenv'

dotenv.config()

const accounts = process.env.MNEMONIC ? {mnemonic: process.env.MNEMONIC} : undefined
const deployer = process.env.DEPLOYER || 0

// Hardhat do not support adding chainId at runtime. Only way to set it in hardhat-config.js
// More info https://github.com/NomicFoundation/hardhat/issues/2167
// To avoid creating a new ENV VAR to store chainId, this function resolves it based on provider url
function resolveChainId() {
  // eslint-disable-next-line @typescript-eslint/no-non-null-assertion
  const NODE_URL = process.env.NODE_URL!
  if (NODE_URL.includes('eth.connect') || NODE_URL.includes('eth-mainnet')) {
    return {chainId: 1, deploy: ['deploy/scripts/mainnet']}
  }
  if (NODE_URL.includes('avax')) {
    return {chainId: 43114, deploy: ['deploy/scripts/avalanche']}
  }
  if (NODE_URL.includes('bsc')) {
    return {chainId: 56, deploy: ['deploy/scripts/bsc']}
  }
  if (NODE_URL.includes('optimism') || NODE_URL.includes('opt-mainnet')) {
    return {chainId: 10, deploy: ['deploy/scripts/optimism']}
  }
  if (NODE_URL.includes('base')) {
    return {chainId: 8453, deploy: ['deploy/scripts/base']}
  }
  return {chainId: 31337, deploy: ['deploy/scripts/mainnet']}
}
const {chainId, deploy} = resolveChainId()

const config: HardhatUserConfig = {
  defaultNetwork: 'hardhat',
  networks: {
    localhost: {
      saveDeployments: true,
      autoImpersonate: true,
      chainId,
      deploy,
    },
    hardhat: {
      // Note: Forking is being made from those test suites that need it
      // forking: {
      //   url: process.env.NODE_URL,
      //   blockNumber: process.env.BLOCK_NUMBER ? parseInt(process.env.BLOCK_NUMBER) : undefined,
      // },
      saveDeployments: true,
      accounts,
      chainId,
    },
    mainnet: {
      url: process.env.NODE_URL,
      chainId: 1,
      gas: 6700000,
      accounts,
      deploy: ['deploy/scripts/mainnet'],
    },
    avalanche: {
      url: process.env.NODE_URL,
      chainId: 43114,
      gas: 8000000,
      accounts,
    },
    bsc: {
      url: process.env.NODE_URL || '',
      chainId: 56,
      gas: 8000000,
      deploy: ['deploy/scripts/bsc'],
      accounts,
    },
    optimism: {
      url: process.env.NODE_URL || '',
      chainId: 10,
      gas: 8000000,
      deploy: ['deploy/scripts/optimism'],
      accounts,
    },
    base: {
      url: process.env.NODE_URL || '',
      chainId: 8453,
      gas: 8000000,
      deploy: ['deploy/scripts/base'],
      accounts,
    },
  },
  paths: {
    // Note: Uses mainnet folder as default
    deploy: ['deploy/scripts/mainnet'],
  },
  namedAccounts: {
    deployer,
  },
  contractSizer: {
    alphaSort: true,
    runOnCompile: process.env.RUN_CONTRACT_SIZER === 'true',
    disambiguatePaths: false,
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS === 'true',
    outputFile: 'gas-report.txt',
    noColors: true,
    excludeContracts: ['mock/'],
  },
  solidity: {
    version: '0.8.9',
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      outputSelection: {
        '*': {
          '*': ['storageLayout'],
        },
      },
    },
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
  spdxLicenseIdentifier: {
    overwrite: false,
    runOnCompile: true,
  },
  typechain: {
    outDir: 'typechain',
  },
  mocha: {
    timeout: 200000,
    // Note: We can enable parallelism here instead of using the `--parallel`
    // flag on npm script but it would make coverage to fail
    // parallel: true
  },
}

export default config
