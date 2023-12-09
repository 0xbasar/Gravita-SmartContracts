// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "./Addresses.sol";
import "./Dependencies/SafetyTransfer.sol";
import "./Interfaces/IActivePool.sol";
import "./Interfaces/IAdminContract.sol";
import "./Interfaces/IInterestIncurringTokenizedVault.sol";

/*
 * The Active Pool holds the collaterals and debt amounts for all active vessels.
 *
 * When a vessel is liquidated, it's collateral and debt tokens are transferred from the Active Pool, to either the
 * Stability Pool, the Default Pool, or both, depending on the liquidation conditions.
 *
 */
contract ActivePool is OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, IActivePool, Addresses {
	using SafeERC20Upgradeable for IERC20Upgradeable;
	using ERC165Checker for address;

	string public constant NAME = "ActivePool";

	mapping(address => uint256) internal assetsBalances;
	mapping(address => uint256) internal debtTokenBalances;

	// --- Modifiers ---

	modifier callerIsBorrowerOpsOrDefaultPool() {
		require(
			msg.sender == borrowerOperations || msg.sender == defaultPool,
			"ActivePool: Caller is not an authorized Gravita contract"
		);
		_;
	}

	modifier callerIsBorrowerOpsOrVesselMgr() {
		require(
			msg.sender == borrowerOperations || msg.sender == vesselManager,
			"ActivePool: Caller is not an authorized Gravita contract"
		);
		_;
	}

	modifier callerIsBorrowerOpsOrStabilityPoolOrVesselMgr() {
		require(
			msg.sender == borrowerOperations || msg.sender == stabilityPool || msg.sender == vesselManager,
			"ActivePool: Caller is not an authorized Gravita contract"
		);
		_;
	}

	modifier callerIsBorrowerOpsOrStabilityPoolOrVesselMgrOrVesselMgrOps() {
		require(
			msg.sender == borrowerOperations ||
				msg.sender == stabilityPool ||
				msg.sender == vesselManager ||
				msg.sender == vesselManagerOperations,
			"ActivePool: Caller is not an authorized Gravita contract"
		);
		_;
	}

	// --- Initializer ---

	function initialize() public initializer {
		__Ownable_init();
		__ReentrancyGuard_init();
		__UUPSUpgradeable_init();
	}

	// --- Getters for public variables. Required by IPool interface ---

	function getAssetBalance(address _asset) external view override returns (uint256) {
		return assetsBalances[_asset];
	}

	function getDebtTokenBalance(address _asset) external view override returns (uint256) {
		return debtTokenBalances[_asset];
	}

	function increaseDebt(address _collateral, uint256 _amount) external override callerIsBorrowerOpsOrVesselMgr {
		uint256 newDebt = debtTokenBalances[_collateral] + _amount;
		debtTokenBalances[_collateral] = newDebt;
		emit ActivePoolDebtUpdated(_collateral, newDebt);
	}

	function decreaseDebt(
		address _asset,
		uint256 _amount
	) external override callerIsBorrowerOpsOrStabilityPoolOrVesselMgr {
		uint256 newDebt = debtTokenBalances[_asset] - _amount;
		debtTokenBalances[_asset] = newDebt;
		emit ActivePoolDebtUpdated(_asset, newDebt);
	}

	// --- Pool functionality ---

	function sendAsset(
		address _asset,
		address _account,
		uint256 _amount
	)
		external
		override
		nonReentrant
		callerIsBorrowerOpsOrStabilityPoolOrVesselMgrOrVesselMgrOps
		returns (address _assetSent, uint256 _amountSent)
	{
		uint256 _safetyTransferAmount = SafetyTransfer.decimalsCorrection(_asset, _amount);
		if (_safetyTransferAmount == 0) {
			return (_asset, 0);
		}

		uint256 _newBalance = assetsBalances[_asset] - _amount;
		assetsBalances[_asset] = _newBalance;
		emit ActivePoolAssetBalanceUpdated(_asset, _newBalance);

		// wrapped assets need to be withdrawn from vault (unless being sent to CollSurplusPool, DefaultPool or StabilityPool)
		bool _assetNeedsUnwrap = _asset.supportsInterface(type(IInterestIncurringTokenizedVault).interfaceId) &&
			(_account != collSurplusPool) &&
			(_account != defaultPool) &&
			(_account != stabilityPool);

		if (_assetNeedsUnwrap) {
			_assetSent = IInterestIncurringTokenizedVault(_asset).asset();
			_amountSent = IInterestIncurringTokenizedVault(_asset).redeem(_amount, _account, address(this));
			if (isERC20DepositContract(_account)) {
				IDeposit(_account).receivedERC20(_assetSent, _amountSent);
			}
			emit AssetSent(_account, _assetSent, _amountSent);
		} else {
			_assetSent = _asset;
			_amountSent = _safetyTransferAmount;
			IERC20Upgradeable(_asset).safeTransfer(_account, _safetyTransferAmount);
			if (isERC20DepositContract(_account)) {
				IDeposit(_account).receivedERC20(_asset, _safetyTransferAmount);
			}
			emit AssetSent(_account, _asset, _safetyTransferAmount);
		}
	}

	function isERC20DepositContract(address _account) private view returns (bool) {
		return (_account == defaultPool || _account == collSurplusPool || _account == stabilityPool);
	}

	function receivedERC20(address _asset, uint256 _amount) external override callerIsBorrowerOpsOrDefaultPool {
		uint256 newBalance = assetsBalances[_asset] + _amount;
		assetsBalances[_asset] = newBalance;
		emit ActivePoolAssetBalanceUpdated(_asset, newBalance);
	}

	function authorizeUpgrade(address newImplementation) public {
		_authorizeUpgrade(newImplementation);
	}

	function _authorizeUpgrade(address) internal override onlyOwner {}
}
