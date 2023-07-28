// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Interfaces/IBooster.sol";
import "./Interfaces/IConvexDeposits.sol";
import "./Interfaces/IRewardStaking.sol";
import "./Interfaces/ITokenWrapper.sol";

import "../../Interfaces/ICollSurplusPool.sol";
import "../../Interfaces/IRewardAccruing.sol";
import "../../Interfaces/IStabilityPool.sol";
import "../../Interfaces/IVesselManager.sol";
import "../../Addresses.sol";

import "@openzeppelin/contracts/utils/Strings.sol"; //debug
import "hardhat/console.sol"; //debug

/**
 * @dev Wrapper based upon https://github.com/convex-eth/platform/blob/main/contracts/contracts/wrappers/ConvexStakingWrapper.sol
 */
contract ConvexStakingWrapper is
	OwnableUpgradeable,
	UUPSUpgradeable,
	ReentrancyGuardUpgradeable,
	PausableUpgradeable,
	ERC20Upgradeable,
	IRewardAccruing,
	Addresses
{
	using SafeERC20 for IERC20;

	// Events -----------------------------------------------------------------------------------------------------------

	event RewardAccruingRightsTransferred(address _from, address _to, uint256 _amount);

	// Structs ----------------------------------------------------------------------------------------------------------

	struct RewardEarned {
		address token;
		uint256 amount;
	}

	struct RewardType {
		address token;
		address pool;
		uint256 integral;
		uint256 remaining;
		mapping(address => uint256) integralFor;
		mapping(address => uint256) claimableAmount;
	}

	// Events -----------------------------------------------------------------------------------------------------------

	event Deposited(address indexed _user, address indexed _account, uint256 _amount, bool _wrapped);
	event Withdrawn(address indexed _user, uint256 _amount, bool _unwrapped);
	event RewardInvalidated(address _rewardToken);
	event RewardRedirected(address indexed _account, address _forward);
	event RewardAdded(address _token);
	event UserCheckpoint(address _userA, address _userB);
	event ProtocolFeeChanged(uint256 oldProtocolFee, uint256 newProtocolFee);

	// Constants/Immutables ---------------------------------------------------------------------------------------------

	address public constant convexBooster = address(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
	address public constant crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
	address public constant cvx = address(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
	address public curveToken;
	address public convexToken;
	address public convexPool;
	uint256 public convexPoolId;
	uint256 private constant CRV_INDEX = 0;
	uint256 private constant CVX_INDEX = 1;

	// State ------------------------------------------------------------------------------------------------------------

	RewardType[] public rewards;
	mapping(address => uint256) public registeredRewards; // rewardToken -> index in rewards[] + 1
	mapping(address => address) public rewardRedirect; // account -> redirectTo
	uint256 public protocolFee = 0.15 ether;

	// Constructor/Initializer ------------------------------------------------------------------------------------------

	function initialize(uint256 _poolId) external initializer {
		__ERC20_init("GravitaCurveToken", "grCRV");
		__Ownable_init();
		__UUPSUpgradeable_init();

		(address _lptoken, address _token, , address _rewards, , ) = IBooster(convexBooster).poolInfo(_poolId);
		curveToken = _lptoken;
		convexToken = _token;
		convexPool = _rewards;
		convexPoolId = _poolId;

		_addRewards();
		_setApprovals();
	}

	// Admin (Owner) functions ------------------------------------------------------------------------------------------

	function addTokenReward(address _token) public onlyOwner {
		// check if not registered yet
		if (registeredRewards[_token] == 0) {
			RewardType storage newReward = rewards.push();
			newReward.token = _token;
			registeredRewards[_token] = rewards.length; //mark registered at index+1
			/// @dev commented the transfer below until understanding its value
			// send to self to warmup state
			// IERC20(_token).transfer(address(this), 0);
			emit RewardAdded(_token);
		} else {
			// get previous used index of given token
			// this ensures that reviving can only be done on the previous used slot
			uint256 _index = registeredRewards[_token];
			if (_index != 0) {
				// index is registeredRewards minus one
				RewardType storage reward = rewards[_index - 1];
				// check if it was invalidated
				if (reward.token == address(0)) {
					// revive
					reward.token = _token;
					emit RewardAdded(_token);
				}
			}
		}
	}

	/**
	 * @dev Allows for reward invalidation, in case the token has issues during calcRewardsIntegrals.
	 */
	function invalidateReward(address _token) public onlyOwner {
		uint256 _index = registeredRewards[_token];
		if (_index != 0) {
			// index is registered rewards minus one
			RewardType storage reward = rewards[_index - 1];
			require(reward.token == _token, "!mismatch");
			// set reward token address to 0, integral calc will now skip
			reward.token = address(0);
			emit RewardInvalidated(_token);
		}
	}

	function pause() external onlyOwner {
		_pause();
	}

	function unpause() external onlyOwner {
		_unpause();
	}

	// Public functions -------------------------------------------------------------------------------------------------

	function depositCurveTokens(uint256 _amount, address _to) external whenNotPaused {
		if (_amount != 0) {
			// no need to call _checkpoint() since _mint() will
			_mint(_to, _amount);
			IERC20(curveToken).safeTransferFrom(msg.sender, address(this), _amount);
			/// @dev the `true` argument below means the Booster contract will immediately stake into the rewards contract
			IConvexDeposits(convexBooster).deposit(convexPoolId, _amount, true);
			emit Deposited(msg.sender, _to, _amount, true);
		}
	}

	function stakeConvexTokens(uint256 _amount, address _to) external whenNotPaused {
		if (_amount != 0) {
			// no need to call _checkpoint() since _mint() will
			_mint(_to, _amount);
			IERC20(convexToken).safeTransferFrom(msg.sender, address(this), _amount);
			IRewardStaking(convexPool).stake(_amount);
			emit Deposited(msg.sender, _to, _amount, false);
		}
	}

	/**
	 * @notice Function that returns all claimable rewards for a specific user.
	 * @dev One should call the mutable userCheckpoint() function beforehand for updating the state for
	 *     the most up-to-date results.
	 */
	function getEarnedRewards(address _account) external view returns (RewardEarned[] memory _claimable) {
		uint256 _rewardCount = rewards.length;
		_claimable = new RewardEarned[](_rewardCount);
		for (uint256 _i; _i < _rewardCount; ) {
			RewardType storage reward = rewards[_i];
			if (reward.token != address(0)) {
				_claimable[_i].amount = reward.claimableAmount[_account];
				_claimable[_i].token = reward.token;
			}
			unchecked {
				++_i;
			}
		}
	}

	/**
	 * from https://github.com/convex-eth/platform/blob/main/contracts/contracts/Booster.sol
	 * "Claim crv and extra rewards and disperse to reward contracts"
	 */
	function earmarkBoosterRewards() external returns (bool) {
		return IBooster(convexBooster).earmarkRewards(convexPoolId);
	}

	function userCheckpoint() external {
		_checkpoint([msg.sender, address(0)], false);
	}

	function userCheckpoint(address _account) external {
		_checkpoint([_account, address(0)], false);
	}

	function claimEarnedRewards(address _account) external {
		address _redirect = rewardRedirect[_account];
		address _destination = _redirect != address(0) ? _redirect : _account;
		_checkpoint([_account, _destination], true);
	}

	function claimAndForwardEarnedRewards(address _account, address _forwardTo) external {
		require(msg.sender == _account, "!self");
		_checkpoint([_account, _forwardTo], true);
	}

	function claimTreasuryEarnedRewards(uint256 _index) external {
		RewardType storage reward = rewards[_index];
		if (reward.token != address(0)) {
			uint256 _amount = reward.claimableAmount[treasuryAddress];
			if (_amount != 0) {
				reward.claimableAmount[treasuryAddress] = 0;
				IERC20(reward.token).safeTransfer(treasuryAddress, _amount);
			}
		}
	}

	/**
	 * @notice Collateral on the Gravita Protocol is stored in different pools based on its lifecycle status.
	 *     Borrowers will accrue rewards while their collateral is in:
	 *         - ActivePool (queried via VesselManager), meaning their vessel is active
	 *         - CollSurplusPool, meaning their vessel was liquidated/redeemed against and there was a surplus
	 *     Gravita will accrue rewards while collateral is in:
	 *         - DefaultPool, meaning collateral got redistributed during a liquidation
	 *         - StabilityPool, meaning collateral got offset against deposits and turned into gains waiting for claiming
	 *
	 * @dev View https://docs.google.com/document/d/1j6mcK4iB3aWfPSH3l8UdYL_G3sqY3k0k1G4jt81OsRE/edit?usp=sharing
	 */
	function gravitaBalanceOf(address _account) public view returns (uint256 _collateral) {
		if (_account == treasuryAddress) {
			_collateral = IPool(defaultPool).getAssetBalance(address(this));
			_collateral += IStabilityPool(stabilityPool).getCollateral(address(this));
		} else {
			_collateral = IVesselManager(vesselManager).getVesselColl(address(this), _account);
			_collateral += ICollSurplusPool(collSurplusPool).getCollateral(address(this), _account);
		}
	}

	function totalBalanceOf(address _account) public view returns (uint256) {
		if (_account == address(0) || _isGravitaPool(_account)) {
			return 0;
		}
		return balanceOf(_account) + gravitaBalanceOf(_account);
	}

	function rewardsLength() external view returns (uint256) {
		return rewards.length;
	}

	/**
	 * @notice Set any claimed rewards to automatically go to a different address.
	 * @dev Set to zero to disable redirect.
	 */
	function setRewardRedirect(address _to) external nonReentrant {
		rewardRedirect[msg.sender] = _to;
		emit RewardRedirected(msg.sender, _to);
	}

	function transferRewardAccruingRights(
		address _from,
		address _to,
		uint256 _amount
	) external override onlyDefaultPoolOrStabilityPoolOrVesselManagerOperations {
		console.log("transferRewardAccruingRights(%s, %s, %s)", addrToName(_from), addrToName(_to), f(_amount));
		_checkpoint([_from, _to], false);
		emit RewardAccruingRightsTransferred(_from, _to, _amount);
	}

	// withdraw to convex deposit token
	function withdraw(uint256 _amount) external {
		if (_amount != 0) {
			// no need to call _checkpoint() since _burn() will
			_burn(msg.sender, _amount);
			IRewardStaking(convexPool).withdraw(_amount, false);
			IERC20(convexToken).safeTransfer(msg.sender, _amount);
			emit Withdrawn(msg.sender, _amount, false);
		}
	}

	// withdraw to underlying curve lp token
	function withdrawAndUnwrap(uint256 _amount) external {
		if (_amount != 0) {
			// no need to call _checkpoint() since _burn() will
			_burn(msg.sender, _amount);
			IRewardStaking(convexPool).withdrawAndUnwrap(_amount, false);
			IERC20(curveToken).safeTransfer(msg.sender, _amount);
			emit Withdrawn(msg.sender, _amount, true);
		}
	}

	// Internal/Helper functions ----------------------------------------------------------------------------------------

	function _addRewards() internal {
		address _convexPool = convexPool;
		if (rewards.length == 0) {
			RewardType storage newCrvReward = rewards.push();
			newCrvReward.token = crv;
			newCrvReward.pool = _convexPool;
			RewardType storage newCvxReward = rewards.push();
			newCvxReward.token = cvx;
			registeredRewards[crv] = CRV_INDEX + 1;
			registeredRewards[cvx] = CVX_INDEX + 1;
			/// @dev commented the transfer below until understanding its value
			// send to self to warmup state
			// IERC20(crv).transfer(address(this), 0);
			// send to self to warmup state
			// IERC20(cvx).transfer(address(this), 0);
			emit RewardAdded(crv);
			emit RewardAdded(cvx);
		}
		uint256 _extraCount = IRewardStaking(_convexPool).extraRewardsLength();
		for (uint256 _i; _i < _extraCount; ) {
			address _extraPool = IRewardStaking(_convexPool).extraRewards(_i);
			address _extraToken = IRewardStaking(_extraPool).rewardToken();
			// from pool 151, extra reward tokens are wrapped
			if (convexPoolId >= 151) {
				_extraToken = ITokenWrapper(_extraToken).token();
			}
			if (_extraToken == cvx) {
				// update cvx reward pool address
				rewards[CVX_INDEX].pool = _extraPool;
			} else if (registeredRewards[_extraToken] == 0) {
				// add new token to list
				RewardType storage newReward = rewards.push();
				newReward.token = _extraToken;
				newReward.pool = _extraPool;
				registeredRewards[_extraToken] = rewards.length;
				emit RewardAdded(_extraToken);
			}
			unchecked {
				++_i;
			}
		}
	}

	function _setApprovals() internal {
		IERC20(curveToken).safeApprove(convexBooster, 0);
		IERC20(curveToken).safeApprove(convexBooster, type(uint256).max);
		IERC20(convexToken).safeApprove(convexPool, 0);
		IERC20(convexToken).safeApprove(convexPool, type(uint256).max);
	}

	function _isGravitaPool(address _address) internal view returns (bool) {
		return
			_address == activePool || _address == collSurplusPool || _address == defaultPool || _address == stabilityPool;
	}

	/**
	 * @dev Override function from ERC20: "Hook that is called before any transfer of tokens. This includes
	 *     minting and burning."
	 */
	function _beforeTokenTransfer(address _from, address _to, uint256 /* _amount */) internal override {
		_checkpoint([_from, _to], false);
	}

	/// @param _accounts[0] from address
	/// @param _accounts[1] to address
	/// @param _claim flag to perform rewards claiming
	function _checkpoint(address[2] memory _accounts, bool _claim) internal nonReentrant {
		if (_isGravitaPool(_accounts[0]) || _isGravitaPool(_accounts[1])) {
			// ignore checkpoints that involve Gravita pool contracts
			return;
		}
		console.log("checkpoint(%s, %s, %s)", addrToName(_accounts[0]), addrToName(_accounts[1]), _claim);
		uint256[2] memory _depositedBalances;
		_depositedBalances[0] = totalBalanceOf(_accounts[0]);
		console.log(" - totalBalanceOf_0: %s", f(_depositedBalances[0]));
		if (!_claim) {
			// on a claim call, only do the first slot
			_depositedBalances[1] = totalBalanceOf(_accounts[1]);
			console.log(" - totalBalanceOf_1: %s", f(_depositedBalances[1]));
		}
		// don't claim rewards directly if paused -- can still technically claim via unguarded calls
		// but skipping here protects against outside calls reverting
		if (!paused()) {
			IRewardStaking(convexPool).getReward(address(this), true);
		}
		uint256 _supply = totalSupply();
		uint256 _rewardCount = rewards.length;
		for (uint256 _i; _i < _rewardCount; ) {
			_calcRewardsIntegrals(_i, _accounts, _depositedBalances, _supply, _claim);
			unchecked {
				++_i;
			}
		}
		emit UserCheckpoint(_accounts[0], _accounts[1]);
	}

	function _calcRewardsIntegrals(
		uint256 _index,
		address[2] memory _accounts,
		uint256[2] memory _balances,
		uint256 _supply,
		bool _isClaim
	) internal {
		RewardType storage reward = rewards[_index];
		if (reward.token == address(0)) {
			// token address could have been reset by invalidateReward()
			return;
		}

		// get difference in contract balance and remaining rewards
		// getReward is unguarded so we use reward.remaining to keep track of how much was actually claimed
		uint256 _contractBalance = IERC20(reward.token).balanceOf(address(this));

		// check whether balance increased, and update integral if needed
		if (_supply > 0 && _contractBalance > reward.remaining) {
			uint256 _diff = ((_contractBalance - reward.remaining) * 1e20) / _supply;
			reward.integral += _diff;
		}

		// update user (and treasury) integrals
		for (uint256 _i; _i < _accounts.length; ) {
			address _account = _accounts[_i];
			if (_account != address(0) && !_isGravitaPool(_account)) {
				uint _accountIntegral = reward.integralFor[_account];
				if (_isClaim || _accountIntegral < reward.integral) {
					// reward.claimableAmount[_accounts[_i]] contains the current claimable amount, to that we add
					// add(_balances[_i].mul(reward.integral.sub(_accountIntegral)) => token_balance * (general_reward/token - user_claimed_reward/token)

					uint256 _newClaimableAmount = (_balances[_i] * (reward.integral - _accountIntegral)) / 1e20;
					uint256 _rewardAmount = reward.claimableAmount[_account] + _newClaimableAmount;

					if (_rewardAmount != 0) {
						uint256 _userRewardAmount = (_rewardAmount * (1 ether - protocolFee)) / 1 ether;
						uint256 _treasuryRewardAmount = _rewardAmount - _userRewardAmount;

						if (_isClaim) {
							reward.claimableAmount[_account] = 0;
							IERC20(reward.token).safeTransfer(_accounts[_i + 1], _userRewardAmount); // on a claim, the second address is the forwarding address
							_contractBalance -= _rewardAmount;
							console.log(
								" - reward[%s].transferTo(%s): %s",
								addrToName(reward.token),
								addrToName(_account),
								f(_userRewardAmount)
							);
						} else {
							console.log(
								" - reward[%s].claimableAmount[%s]: %s",
								addrToName(reward.token),
								addrToName(_account),
								f(_userRewardAmount)
							);
							reward.claimableAmount[_account] = _userRewardAmount;
						}
						reward.claimableAmount[treasuryAddress] += _treasuryRewardAmount;
					} else console.log(" - rewardAmount[%s] for account %s is zero", addrToName(reward.token), _i);
					reward.integralFor[_account] = reward.integral;
				}
				if (_isClaim) {
					break; // only update/claim for first address (second address is the forwarding address)
				}
			}
			unchecked {
				++_i;
			}
		}

		// update remaining reward here since balance could have changed (on a claim)
		if (_contractBalance != reward.remaining) {
			reward.remaining = _contractBalance;
		}
	}

	// Timelock functions -----------------------------------------------------------------------------------------------

	function setProtocolFee(uint256 _newfee) external onlyTimelock {
		uint256 _oldFee = protocolFee;
		protocolFee = _newfee;
		emit ProtocolFeeChanged(_oldFee, _newfee);
	}

	// Modifiers --------------------------------------------------------------------------------------------------------

	modifier onlyTimelock() {
		require(timelockAddress == msg.sender, "Only Timelock");
		_;
	}

	modifier onlyDefaultPoolOrStabilityPoolOrVesselManagerOperations() {
		require(
			msg.sender == defaultPool || msg.sender == stabilityPool || msg.sender == vesselManagerOperations,
			"ConvexStakingWrapper: Caller is not an authorized Gravita contract"
		);
		_;
	}

	// Upgrades ---------------------------------------------------------------------------------------------------------

	function authorizeUpgrade(address newImplementation) public {
		_authorizeUpgrade(newImplementation);
	}

	function _authorizeUpgrade(address) internal override onlyOwner {}

	// TEMP/DEBUG -------------------------------------------------------------------------------------------------------

	/**
	 * TEMPORARY formatting/debug/helper functions
	 * TODO remove for production deployment
	 */

	function addrToName(address anAddress) internal view returns (string memory) {
		if (anAddress == activePool) return "ActivePool";
		if (anAddress == collSurplusPool) return "CollSurplusPool";
		if (anAddress == defaultPool) return "DefaultPool";
		if (anAddress == stabilityPool) return "StabilityPool";
		if (anAddress == crv) return "CRV";
		if (anAddress == cvx) return "CVX";
		return addrToStr(anAddress);
	}

	function addrToStr(address _addr) public pure returns (string memory) {
		bytes32 value = bytes32(uint256(uint160(_addr)));
		bytes memory alphabet = "0123456789abcdef";
		bytes memory str = new bytes(51);
		str[0] = "0";
		str[1] = "x";
		for (uint256 i = 0; i < 2; i++) {
			str[2 + i * 2] = alphabet[uint8(value[i + 12] >> 4)];
			str[3 + i * 2] = alphabet[uint8(value[i + 12] & 0x0f)];
		}
		return string(str);
	}

	function f(uint256 value) internal pure returns (string memory) {
		string memory sInput = Strings.toString(value);
		bytes memory bInput = bytes(sInput);
		uint256 len = bInput.length > 18 ? bInput.length + 1 : 20;
		string memory sResult = new string(len);
		bytes memory bResult = bytes(sResult);
		if (bInput.length <= 18) {
			bResult[0] = "0";
			bResult[1] = ".";
			for (uint256 i = 1; i <= 18 - bInput.length; i++) bResult[i + 1] = "0";
			for (uint256 i = bInput.length; i > 0; i--) bResult[--len] = bInput[i - 1];
		} else {
			uint256 c = 0;
			uint256 i = bInput.length;
			while (i > 0) {
				bResult[--len] = bInput[--i];
				if (++c == 18) bResult[--len] = ".";
			}
		}
		return string(bResult);
	}
}
