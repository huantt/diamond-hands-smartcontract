const diamondHands = artifacts.require("DiamondHands")
module.exports = function (_deployer) {
    require('dotenv').config();
    // Use deployer to state migration tasks.
    _deployer.deploy(diamondHands, process.env.SUPPORTED_UNISWAP_ROUTERS.split(','));
};
