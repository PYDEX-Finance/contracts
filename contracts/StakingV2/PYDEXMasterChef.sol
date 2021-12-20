// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
}

import "./PYDEXReferral.sol";

interface IPRVNFTInterface {
    function approve(address to, uint256 tokenId) external;

    function balanceOf(address owner) external view returns (uint256);

    function diamondSupply() external view returns (uint256);

    function getApproved(uint256 tokenId) external view returns (address);

    function goldSupply() external view returns (uint256);

    function isApprovedForAll(address owner, address operator)
        external
        view
        returns (bool);

    function ownerOf(uint256 tokenId) external view returns (address);

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function setApprovalForAll(address operator, bool approved) external;

    function supportsInterface(bytes4 interfaceId) external view returns (bool);

    function tokenByIndex(uint256 index) external view returns (uint256);

    function tokenOfOwnerByIndex(address owner, uint256 index)
        external
        view
        returns (uint256);

    function tokenTypes(uint256) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function transferOwnership(address newOwner) external;

    function withdraw() external;

    function flipSaleState() external;

    function withdrawAllFunds() external;

    function withdrawToken(address _token) external;
}

/**
 * @title ERC721 token receiver interface
 * @dev Interface for any contract that wants to support safeTransfers
 * from ERC721 asset contracts.
 */
interface IERC721Receiver {
    /**
     * @dev Whenever an {IERC721} `tokenId` token is transferred to this contract via {IERC721-safeTransferFrom}
     * by `operator` from `from`, this function is called.
     *
     * It must return its Solidity selector to confirm the token transfer.
     * If any other value is returned or the interface is not implemented by the recipient, the transfer will be reverted.
     *
     * The selector can be obtained in Solidity with `IERC721.onERC721Received.selector`.
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

contract PYDEXGMasterChef is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    IPRVNFTInterface public _privacyNFT;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 stakedNFTId;
        uint256 nftRewardDebt;

        //
        // We do some fancy math here. Basically, any point in time, the amount of PYDEXs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accPydexPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accPydexPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. PYDEXs to distribute per block.
        uint256 lastRewardBlock; // Last block number that PYDEXs distribution occurs.
        uint256 accPydexPerShare;
        uint256 accPydexPerSilverNFTShare;
        uint256 accPydexPerGoldNFTShare;
        uint256 accPydexPerDiamondNFTShare;
        uint256 silverNFTsLocked;
        uint256 goldNFTsLocked;
        uint256 diamondNFTsLocked;
        bool isNFTStakingEnabled;
        uint16 depositFeeBP; // Deposit fee in basis points
    }

    mapping(address => bool) public poolsList;

    uint256 constant TYPE_SILVER_NFT_RATIO = 200; // 20%
    uint256 constant TYPE_GOLD_NFT_RATIO = 300; // 30%
    uint256 constant TYPE_DIAMOND_NFT_RATIO = 500; // 50%
    uint256 public constant nftRewardSplitPercent = 200; // 20%

    IBEP20 public pydex;
    // Dev address.
    address public devAddress;
    // Deposit Fee address
    address public feeAddress;
    // PYDEX tokens created per block.
    uint256 public pydexPerBlock;
    // Bonus muliplier for early pydex makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when PYDEX mining starts.
    uint256 public startBlock;

    // Pydex referral contract address.
    PYDEXReferral public pydexReferral;

    event onPoolAdded(
        uint256 _allocPoint,
        IBEP20 _lpToken,
        uint16 _depositFeeBP,
        bool _withUpdate
    );
    event onPoolSet(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        bool _withUpdate
    );

    event Deposit(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        uint256 refCommission
    );
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event EmissionRateUpdated(
        address indexed caller,
        uint256 previousAmount,
        uint256 newAmount
    );
    event ReferralCommissionPaid(
        address indexed user,
        address indexed referrer,
        uint256 commissionAmount
    );

    event onSetFeeAddress(address previousAddress, address newAddress);
    event onSetPydexReferral(address previousAddress, address newAddress);
    event onRewardPaid(
        address user,
        uint256 firstLevelCommission,
        uint256 secondevelCommission,
        uint256 thirdLevelCommission,
        uint256 remainingReward
    );

    event onPRVNFTSet(address previousPRVNFT, address newPRVNFT);
    event onNFTReceived(
        address operator,
        address from,
        uint256 tokenId,
        bytes data
    );
    event onNFTStaked(uint256 pid, uint256 nftID);
    event onNFTUnstaked(uint256 pid, uint256 nftID);

    constructor(
        IBEP20 _pydex,
        uint256 _startBlock,
        uint256 _pydexPerBlock
    ) {
        pydex = _pydex;
        startBlock = _startBlock;
        pydexPerBlock = _pydexPerBlock;
        devAddress = msg.sender;
        feeAddress = msg.sender;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function setPRVNft(IPRVNFTInterface privacyNFT) public onlyOwner {
        emit onPRVNFTSet(address(_privacyNFT), address(privacyNFT));
        if (address(_privacyNFT) != address(0)) {
            require(_privacyNFT.balanceOf(address(this)) == 0, "Staked in MC");
        }
        _privacyNFT = privacyNFT;
    }

    function onERC721Received(
        address _operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        emit onNFTReceived(_operator, from, tokenId, data);
        return 0x150b7a02;
    }

    function stakeNFT(uint256 _pid, uint256 nftID) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        require(address(pool.lpToken) != address(0), "Invalid Pool");
        require(pool.isNFTStakingEnabled, "Can't Stake in this Pool");
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount > 0, "Can't Stake NFT without staking Token");
        require(user.stakedNFTId == 0, "NFT already staked");
        updatePool(_pid);
        payPendingReward(_pid);
        _privacyNFT.safeTransferFrom(msg.sender, address(this), nftID);
        user.stakedNFTId = nftID;
        user.rewardDebt = user.amount.mul(pool.accPydexPerShare).div(1e18);

        uint256 nftType = _privacyNFT.tokenTypes(nftID);

        if (nftType == 1) {
            pool.silverNFTsLocked = pool.silverNFTsLocked.add(1);
            user.nftRewardDebt = user
                .amount
                .mul(pool.accPydexPerSilverNFTShare)
                .div(1e18)
                .sub(user.nftRewardDebt);
        } else if (nftType == 2) {
            pool.goldNFTsLocked = pool.goldNFTsLocked.add(1);
            user.nftRewardDebt = user
                .amount
                .mul(pool.accPydexPerGoldNFTShare)
                .div(1e18)
                .sub(user.nftRewardDebt);
        } else if (nftType == 3) {
            pool.silverNFTsLocked = pool.silverNFTsLocked.add(1);
            user.nftRewardDebt = user
                .amount
                .mul(pool.accPydexPerDiamondNFTShare)
                .div(1e18);
        } else {
            revert("Invalid NFT");
        }
        emit onNFTStaked(_pid, nftID);
    }

    function unstakeNFT(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        require(address(pool.lpToken) != address(0), "Invalid Pool");
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.stakedNFTId != 0, "No NFT Staked");
        updatePool(_pid);
        payPendingReward(_pid);
        uint256 nftId = user.stakedNFTId;
        user.stakedNFTId = 0;
        user.rewardDebt = user.amount.mul(pool.accPydexPerShare).div(1e18);
        _privacyNFT.safeTransferFrom(address(this), msg.sender, nftId);
        uint256 nftType = _privacyNFT.tokenTypes(nftId);

        if (nftType == 1) {
            pool.silverNFTsLocked = pool.silverNFTsLocked.sub(1);
            user.nftRewardDebt = user
                .amount
                .mul(pool.accPydexPerSilverNFTShare)
                .div(1e18)
                .sub(user.nftRewardDebt);
        } else if (nftType == 2) {
            pool.goldNFTsLocked = pool.goldNFTsLocked.sub(1);
            user.nftRewardDebt = user
                .amount
                .mul(pool.accPydexPerGoldNFTShare)
                .div(1e18)
                .sub(user.nftRewardDebt);
        } else if (nftType == 3) {
            pool.silverNFTsLocked = pool.silverNFTsLocked.sub(1);
            user.nftRewardDebt = user
                .amount
                .mul(pool.accPydexPerDiamondNFTShare)
                .div(1e18);
        } else {
            revert("Invalid NFT");
        }
        emit onNFTUnstaked(_pid, nftId);
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IBEP20 _lpToken,
        bool isNFTStakingEnabled,
        uint16 _depositFeeBP,
        bool _withUpdate
    ) public onlyOwner {
        require(
            _depositFeeBP <= 10000,
            "add: invalid deposit fee basis points"
        );
        if (_withUpdate) {
            massUpdatePools();
        }
        require(poolsList[address(_lpToken)] == false, "Pool Already Added");
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accPydexPerShare: 0,
                accPydexPerSilverNFTShare: 0,
                accPydexPerGoldNFTShare: 0,
                accPydexPerDiamondNFTShare: 0,
                silverNFTsLocked: 0,
                goldNFTsLocked: 0,
                diamondNFTsLocked: 0,
                depositFeeBP: _depositFeeBP,
                isNFTStakingEnabled: isNFTStakingEnabled
            })
        );

        poolsList[address(_lpToken)] = true;

        emit onPoolAdded(_allocPoint, _lpToken, _depositFeeBP, _withUpdate);
    }

    // Update the given pool's PYDEX allocation point and deposit fee. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool isNFTStakingEnabled,
        uint16 _depositFeeBP,
        bool _withUpdate
    ) public onlyOwner {
        require(
            _depositFeeBP <= 10000,
            "set: invalid deposit fee basis points"
        );
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].isNFTStakingEnabled = isNFTStakingEnabled;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        emit onPoolSet(_pid, _allocPoint, _depositFeeBP, _withUpdate);
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        pure
        returns (uint256)
    {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending PYDEXs on frontend.
    function pendingPYDEX(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accPydexPerShare = pool.accPydexPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number
            );
            uint256 pydexReward = multiplier
                .mul(pydexPerBlock)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            accPydexPerShare = accPydexPerShare.add(
                pydexReward.mul(1e18).div(lpSupply)
            );
        }
        uint256 pending = user.amount.mul(accPydexPerShare).div(1e18).sub(
            user.rewardDebt
        );

        return pending;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);

        //80- 20
        uint256 totalPydexReward = multiplier
            .mul(pydexPerBlock)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);

        //
        if (pydex.totalSupply().add(totalPydexReward) <= pydex.MAX_SUPPLY()) {
            //  mint as normal as not at maxSupply
            pydex.mint(address(this), totalPydexReward);
        } else {
            // mint the difference only to MC, update pydexReward
            totalPydexReward = pydex.MAX_SUPPLY().sub(pydex.totalSupply());
            pydex.mint(address(this), totalPydexReward);
        }
        if (totalPydexReward != 0) {
            if (pool.isNFTStakingEnabled) {
                uint256 accPydexReward = totalPydexReward;
                uint256 nftRewardSplitAmount = totalPydexReward
                    .mul(nftRewardSplitPercent)
                    .div(1000);
                uint256 silverShare = 0;
                uint256 goldShare = 0;
                uint256 diamondShare = 0;

                if (pool.silverNFTsLocked > 0) {
                    silverShare = nftRewardSplitAmount
                        .mul(TYPE_SILVER_NFT_RATIO)
                        .div(1000);
                    pool.accPydexPerSilverNFTShare = pool
                        .accPydexPerSilverNFTShare
                        .add(silverShare.mul(1e18).div(lpSupply));
                }

                if (pool.goldNFTsLocked > 0) {
                    goldShare = nftRewardSplitAmount
                        .mul(TYPE_GOLD_NFT_RATIO)
                        .div(1000);
                    pool.accPydexPerGoldNFTShare = pool
                        .accPydexPerGoldNFTShare
                        .add(goldShare.mul(1e18).div(lpSupply));
                }

                if (pool.goldNFTsLocked > 0) {
                    diamondShare = nftRewardSplitAmount
                        .mul(TYPE_DIAMOND_NFT_RATIO)
                        .div(1000);
                    pool.accPydexPerDiamondNFTShare = pool
                        .accPydexPerDiamondNFTShare
                        .add(diamondShare.mul(1e18).div(lpSupply));
                }

                uint256 totalNFTAllocation = silverShare.add(goldShare).add(
                    diamondShare
                );
                uint256 remainingReward = accPydexReward.sub(
                    totalNFTAllocation
                );

                pool.accPydexPerShare = pool.accPydexPerShare.add(
                    remainingReward.mul(1e18).div(lpSupply)
                );
            } else {
                pool.accPydexPerShare = pool.accPydexPerShare.add(
                    totalPydexReward.mul(1e18).div(lpSupply)
                );
            }
        }
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for PYDEX allocation.
    function deposit(
        uint256 _pid,
        uint256 _amount,
        address _referrer
    ) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (_amount > 0 && address(pydexReferral) != address(0)) {
            pydexReferral.recordReferral(msg.sender, _referrer);
        }

        payPendingReward(_pid);
        uint256 refCommission = 0;
        if (_amount > 0) {
            uint256 preAmount = pool.lpToken.balanceOf(address(this)); // deflationary check
            pool.lpToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            _amount = pool.lpToken.balanceOf(address(this)).sub(preAmount);
            refCommission = payCommissionOnDeposit(
                pool.lpToken,
                _amount,
                msg.sender
            );
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee).sub(
                    refCommission
                );
            } else {
                user.amount = user.amount.add(_amount).sub(refCommission);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accPydexPerShare).div(1e18);

        if (pool.isNFTStakingEnabled && user.stakedNFTId != 0) {
            uint256 nftType = _privacyNFT.tokenTypes(user.stakedNFTId);
            if (nftType == 1) {
                user.nftRewardDebt = user
                    .amount
                    .mul(pool.accPydexPerSilverNFTShare)
                    .div(1e18);
            } else if (nftType == 2) {
                user.nftRewardDebt = user
                    .amount
                    .mul(pool.accPydexPerGoldNFTShare)
                    .div(1e18);
            } else if (nftType == 3) {
                user.nftRewardDebt = user
                    .amount
                    .mul(pool.accPydexPerDiamondNFTShare)
                    .div(1e18);
            }
        }
        emit Deposit(msg.sender, _pid, _amount, refCommission);
    }

    // Withdraw LP tokens from .
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        payPendingReward(_pid);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accPydexPerShare).div(1e18);
        if (pool.isNFTStakingEnabled && user.stakedNFTId != 0) {
            uint256 nftType = _privacyNFT.tokenTypes(user.stakedNFTId);
            if (nftType == 1) {
                user.nftRewardDebt = user
                    .amount
                    .mul(pool.accPydexPerSilverNFTShare)
                    .div(1e18);
            } else if (nftType == 2) {
                user.nftRewardDebt = user
                    .amount
                    .mul(pool.accPydexPerGoldNFTShare)
                    .div(1e18);
            } else if (nftType == 3) {
                user.nftRewardDebt = user
                    .amount
                    .mul(pool.accPydexPerDiamondNFTShare)
                    .div(1e18);
            }
        }
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function payPendingReward(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 normalPending = user
            .amount
            .mul(pool.accPydexPerShare)
            .div(1e18)
            .sub(user.rewardDebt);
        uint256 nftReward = 0;
        if (pool.isNFTStakingEnabled && user.stakedNFTId != 0) {
            uint256 nftType = _privacyNFT.tokenTypes(user.stakedNFTId);
            if (nftType == 1) {
                nftReward = user
                    .amount
                    .mul(pool.accPydexPerSilverNFTShare)
                    .div(1e18)
                    .sub(user.nftRewardDebt);
            } else if (nftType == 2) {
                nftReward = user
                    .amount
                    .mul(pool.accPydexPerGoldNFTShare)
                    .div(1e18)
                    .sub(user.nftRewardDebt);
            } else if (nftType == 3) {
                nftReward = user
                    .amount
                    .mul(pool.accPydexPerDiamondNFTShare)
                    .div(1e18)
                    .sub(user.nftRewardDebt);
            }
        }

        uint256 pending = normalPending.add(nftReward);

        if (pending > 0) {
            (
                address firstLevel,
                address secondLevel,
                address thirdLevel
            ) = pydexReferral.getReferrer(msg.sender);
            uint256 totalCommission = 0;
            uint256 firstLCommission;
            uint256 secondLCommission;
            uint256 thirdLCommission;

            if (firstLevel != address(0)) {
                firstLCommission = pydexReferral
                    .getMyFirstLevelCommissionRate(msg.sender)
                    .mul(pending)
                    .div(1000);
                totalCommission = totalCommission.add(firstLCommission);
                pydexReferral.recordReferralCommission(
                    firstLevel,
                    firstLCommission,
                    1
                );
                safePydexTransfer(firstLevel, firstLCommission);
            }

            if (secondLevel != address(0)) {
                secondLCommission = pydexReferral.secondTier().mul(pending).div(
                        1000
                    );
                totalCommission = totalCommission.add(secondLCommission);
                pydexReferral.recordReferralCommission(
                    secondLevel,
                    secondLCommission,
                    2
                );

                safePydexTransfer(secondLevel, secondLCommission);
            }

            if (thirdLevel != address(0)) {
                thirdLCommission = pydexReferral.thirdTier().mul(pending).div(
                    1000
                );
                totalCommission = totalCommission.add(thirdLCommission);
                pydexReferral.recordReferralCommission(
                    thirdLevel,
                    thirdLCommission,
                    3
                );

                safePydexTransfer(thirdLevel, thirdLCommission);
            }

            safePydexTransfer(msg.sender, pending.sub(totalCommission));
            emit onRewardPaid(
                msg.sender,
                firstLCommission,
                secondLCommission,
                thirdLCommission,
                pending.sub(totalCommission)
            );
        }
    }

    // Safe pydex transfer function, just in case if rounding error causes pool to not have enough PYDEXs.
    function safePydexTransfer(address _to, uint256 _amount) internal {
        uint256 pydexBal = pydex.balanceOf(address(this));
        if (_amount > pydexBal) {
            pydex.transfer(_to, pydexBal);
        } else {
            pydex.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function setDevAddress(address _devAddress) public {
        require(msg.sender == devAddress, "setDevAddress: FORBIDDEN");
        require(_devAddress != address(0), "setDevAddress: ZERO");
        devAddress = _devAddress;
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "setFeeAddress: ZERO");
        emit onSetFeeAddress(feeAddress, _feeAddress);
        feeAddress = _feeAddress;
    }

    // Pancake has to add hidden dummy pools in order to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _newpydexPerBlock) public onlyOwner {
        massUpdatePools();
        emit EmissionRateUpdated(msg.sender, pydexPerBlock, _newpydexPerBlock);
        pydexPerBlock = _newpydexPerBlock;
    }

    // Update the pydex referral contract address by the owner
    function setPydexReferral(PYDEXReferral _pydexReferral) public onlyOwner {
        emit onSetPydexReferral(
            address(pydexReferral),
            address(_pydexReferral)
        );
        _pydexReferral.getReferrer(address(this));
        pydexReferral = _pydexReferral;
    }

    function payCommissionOnDeposit(
        IBEP20 token,
        uint256 amount,
        address user
    ) internal returns (uint256) {
        address refererer = pydexReferral.referrers(user);
        uint256 commissionAmount = 0;
        if (
            refererer != address(0) &&
            pydexReferral.depositCommissionStatuses(refererer)
        ) {
            commissionAmount = amount
                .mul(pydexReferral.DEPOSIT_REFFERAL_COMMISSION())
                .div(1000);
            token.safeTransfer(refererer, commissionAmount);
        }
        return commissionAmount;
    }
}
