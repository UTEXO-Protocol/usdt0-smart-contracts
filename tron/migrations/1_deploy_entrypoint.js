const UtexoSourceEntrypoint = artifacts.require('UtexoSourceEntrypoint');

// command example
// npx tronbox migrate --network shasta \
//   --token=TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t \
//   --oft=TFG4wBaDQ8sHWWP1ACeSGnoNR6RRzevLPt \
//   --dst-eid=30110 \
//   --lz-adapter=0x000000000000000000000000<arb-lzAdapter-address-without-0x> \
//   --owner=<initial-owner-address>

module.exports = function (deployer, network, accounts) {
  if (network === 'development') {
    return;
  }

  console.log('Migration running on network:', network);
  console.log('Deploying UtexoSourceEntrypoint with account:', accounts);

  const args = process.argv.slice(2);
  const tokenArg     = args.find(arg => arg.includes('--token='));
  const oftArg       = args.find(arg => arg.includes('--oft='));
  const dstEidArg    = args.find(arg => arg.includes('--dst-eid='));
  const lzAdapterArg = args.find(arg => arg.includes('--lz-adapter='));
  const ownerArg     = args.find(arg => arg.includes('--owner='));

  if (!tokenArg || !oftArg || !dstEidArg || !lzAdapterArg || !ownerArg) {
    throw new Error(
      'Error: Please specify correct params: ' +
      '--token=<TRC20Address> --oft=<USDT0OFTAddress> ' +
      '--dst-eid=<LZv2EndpointId> --lz-adapter=<DestLZAdapterBytes32> ' +
      '--owner=<InitialOwnerAddress>'
    );
  }

  const token     = tokenArg.split('=')[1];
  const oft       = oftArg.split('=')[1];
  const dstEid    = dstEidArg.split('=')[1];
  const lzAdapter = lzAdapterArg.split('=')[1];
  const owner     = ownerArg.split('=')[1];

  deployer.deploy(UtexoSourceEntrypoint, token, oft, dstEid, lzAdapter, owner);
};
