const UtexoSourceEntrypoint = artifacts.require('UtexoSourceEntrypoint');

// Deploys a source entrypoint from --token, --oft, --dst-eid, --lz-adapter and --owner.

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
