//SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@beehiveinnovation/rain-protocol/contracts/vm/RainVM.sol";
import "@beehiveinnovation/rain-protocol/contracts/tier/libraries/TierReport.sol";
import {AllStandardOps} from "@beehiveinnovation/rain-protocol/contracts/vm/ops/AllStandardOps.sol";
import "@beehiveinnovation/rain-protocol/contracts/vm/VMStateBuilder.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "hardhat/console.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";


struct Rain1155Config {
    address vmStateBuilder;
}

struct CurrencyConfig {
    address[] token;
    uint256[] tokenId;
}

struct AssetConfig {
    string name;
    string description;
    uint256 lootBoxId;
    StateConfig vmStateConfig;
    CurrencyConfig currencies;
    address recipient;
    string tokenURI;
}

contract Rain1155 is ERC1155Supply, RainVM {
    using Strings for uint256;
    using Math for uint256;

    uint256 public totalAssets;

    address private immutable self;
    address private immutable vmStateBuilder;

    mapping(uint256 => mapping(address => uint256)) private paymentToken;

    mapping(uint256 => AssetDetails) public assets;

    struct AssetDetails {
        uint256 lootBoxId;
        uint256 id;
        StateConfig vmStateConfig;
        address vmStatePointer;
        CurrencyConfig currencies;
        address recipient;
        string tokenURI;
    }

    // EVENTS
    event Initialize(address deployer_, Rain1155Config config_);
    event AssetCreated(
        uint256 assetId_,
        AssetDetails asset_,
        string name_,
        string description_
    );

    // EVENTS END

    constructor(Rain1155Config memory config_) ERC1155("") {
        self = address(this);
        vmStateBuilder = config_.vmStateBuilder;
        emit Initialize(msg.sender, config_);
    }

    function _loadState(uint256 assetId_) internal view returns (State memory) {
        return
            LibState.fromBytesPacked(
                SSTORE2.read(assets[assetId_].vmStatePointer)
            );
    }

    function _priceEntryPoint(uint256 assetId_, address paymentToken_)
        internal
        view
        returns (uint256 entrtyPoint)
    {
        entrtyPoint = paymentToken[assetId_][paymentToken_];
        require(assets[assetId_].currencies.token[entrtyPoint] == paymentToken_, "Invalid payment token");
    }

    function getAssetMaxUnits(
        uint256 assetId_,
        address account_,
        uint256 units_
    ) public view returns (uint256) {
        (uint256 maxUnits_, ) = getAssetCost(assetId_, account_, units_);

        return maxUnits_;
    }

    function uri(uint256 _tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        require(exists(_tokenId), "Invalid TokenId.");
        return assets[_tokenId].tokenURI;
    }

    function createNewAsset(AssetConfig memory config_) external {

        for (uint256 i = 0; i < config_.currencies.token.length; i++) {
           getCurrencyType(config_.currencies.token[i]);
        }

        totalAssets = totalAssets + 1;

        Bounds memory calculateCostBound;
        calculateCostBound.entrypoint = 0;

        Bounds[] memory bounds_ = new Bounds[](1);
        bounds_[0] = calculateCostBound;

        for (uint256 i = 0; i < config_.currencies.token.length; i++) {
            paymentToken[totalAssets][config_.currencies.token[i]] = i;
        }

        bytes memory vmStateBytes_ = VMStateBuilder(vmStateBuilder).buildState(
            self,
            config_.vmStateConfig,
            bounds_
        );

        assets[totalAssets] = AssetDetails(
            config_.lootBoxId,
            totalAssets,
            config_.vmStateConfig,
            SSTORE2.write(vmStateBytes_),
            config_.currencies,
            config_.recipient,
            config_.tokenURI
        );

        emit AssetCreated(
            totalAssets,
            assets[totalAssets],
            config_.name,
            config_.description
        );
    }

    function getCurrencyPrice(
        uint256 assetId_,
        address paymentToken_,
        address account_,
        uint256 units_
    )
        public
        view
        returns ( uint256 )
    {
        (, uint256[] memory prices_) = getAssetCost(assetId_, account_, units_);
        uint256 index = _priceEntryPoint(assetId_, paymentToken_);

        return ( prices_[index] );
    }

    function getAssetCost(
        uint256 assetId_,
        address account_,
        uint256 units_
    ) public view returns (uint256, uint256[] memory) {
        uint256[2] memory context_;
        context_[0] = uint256(uint160(account_));
        context_[1] = units_;
        State memory state_ = _loadState(assetId_);
        eval(abi.encodePacked(context_), state_, 0);

        address[] memory tokens = assets[assetId_].currencies.token;
        uint256 stackPointer = state_.stackIndex - 1;
        uint256 maxUnits = state_.stack[state_.stackIndex - 2];
        uint256[] memory prices = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            unchecked {
                uint256 count = tokens.length - (i + 1);
                prices[count] = state_.stack[stackPointer];
                maxUnits = maxUnits.min(state_.stack[stackPointer - 1]);
                stackPointer -= 2;
            }
        }
        return (maxUnits, prices);
    }

    function mintAssets(uint256 assetId_, uint256 units_) external {
        require(assetId_ <= totalAssets, "Invalid AssetId");

        (uint256 maxUnits_, uint256[] memory prices_) = getAssetCost(
            assetId_,
            msg.sender,
            units_
        );
        require(maxUnits_ > 0, "Cant Mint");
        maxUnits_ = maxUnits_.min(units_);

        uint256 count = 0;
        for (uint256 i = 0; i < assets[assetId_].currencies.token.length; i++) {
            
            uint256 tokenType_ = getCurrencyType(assets[assetId_].currencies.token[i]);
            if (prices_[i] > 0) {
                if (tokenType_ == 0) {
                    ITransfer(assets[assetId_].currencies.token[i]).transferFrom(
                        msg.sender,
                        assets[assetId_].recipient,
                        prices_[i] * maxUnits_
                    );
                } else if (tokenType_ == 1) {
                    ITransfer(assets[assetId_].currencies.token[i])
                        .safeTransferFrom(
                            msg.sender,
                            assets[assetId_].recipient,
                            assets[assetId_].currencies.tokenId[count],
                            prices_[i] * maxUnits_,
                            ""
                        );
                    count++;
                }
            }
        }
        _mint(msg.sender, assetId_, maxUnits_, "");
    }

    function getCurrencyType(address token_) internal view returns (uint256) {
        try ERC721(address(uint160(token_))).supportsInterface(0x80ac58cd) returns (bool) {
            return 1;
        } catch  {
            try ERC1155(address(uint160(token_))).supportsInterface(0xd9b67a26) returns (bool) {
                return 1;
            } catch  {
                return 0;
            }
        }
    }

    function fnPtrs() public pure override returns (bytes memory) {
        return AllStandardOps.fnPtrs();
    }
}

interface ITransfer {
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external;

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}