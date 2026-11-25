require('dotenv').config();

const port = process.env.HOST_PORT || 9095;
const treDefaultPrivateKey =
  'da146374a75310b9666e834ee4ad0866d6f4035967bfc76217c5a495fff9f0d0';

module.exports = {
  networks: {
    mainnet: {      
      privateKey: process.env.PRIVATE_KEY_MAINNET,
      userFeePercentage: 100,
      feeLimit: 1000 * 1e6,
      fullHost: 'https://api.trongrid.io',
      network_id: '1'
    },
    shasta: {
      privateKey: process.env.PRIVATE_KEY_SHASTA,
      userFeePercentage: 50,
      feeLimit: 1000 * 1e6,
      fullHost: 'https://api.shasta.trongrid.io',
      network_id: '2'
    },
    nile: {
      privateKey: process.env.PRIVATE_KEY_NILE,
      userFeePercentage: 100,
      feeLimit: 1000 * 1e6,
      fullHost: 'https://nile.trongrid.io',
      network_id: '3'
    },
    development: {
      privateKey: process.env.PRIVATE_KEY_DEVELOPMENT || treDefaultPrivateKey,
      userFeePercentage: 0,
      feeLimit: 1000 * 1e6,
      fullHost: `http://127.0.0.1:${port}`,
      network_id: '9'
    }
  },
  compilers: {
    solc: {
      version: '0.8.26',
      settings: {
        optimizer: {
          enabled: true,
          runs: 200
        },
        evmVersion: 'paris',
        viaIR: true,        
      }
    }
  }
};
