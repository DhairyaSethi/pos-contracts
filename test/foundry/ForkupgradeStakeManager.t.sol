pragma solidity ^0.8.4;

import {StakeManager} from "../../scripts/helpers/interfaces/StakeManager.generated.sol";
import {StakeManagerProxy} from "../../scripts/helpers/interfaces/StakeManagerProxy.generated.sol";
import {ValidatorShare} from "../../scripts/helpers/interfaces/ValidatorShare.generated.sol";
import {DepositManager} from "../../scripts/helpers/interfaces/DepositManager.generated.sol";
import {Registry} from "../../scripts/helpers/interfaces/Registry.generated.sol";
import {ERC20} from "../../scripts/helpers/interfaces/ERC20.generated.sol";
import {Proxy} from "../../scripts/helpers/interfaces/Proxy.generated.sol";

import {UpgradeStake_DepositManager_Mainnet} from "../../scripts/deployers/pol-upgrade/UpgradeStake_DepositManager_Mainnet.s.sol";
import {Timelock} from "../../contracts/common/misc/ITimelock.sol";

import "forge-std/Test.sol";

contract ForkupgradeStakeManagerTest is Test, UpgradeStake_DepositManager_Mainnet {
    uint256 mainnetFork;

    function setUp() public {
        mainnetFork = vm.createFork(vm.rpcUrl("mainnet"));
        vm.selectFork(mainnetFork);
    }

    function test_UpgradeStakeManager() public {
        assertEq(vm.activeFork(), mainnetFork);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        loadConfig();
        (StakeManager stakeManagerImpl, ValidatorShare validatorShareImpl, DepositManager depositManagerImpl) = deployImplementations(deployerPrivateKey);
        (bytes memory scheduleBatchPayload, bytes memory executeBatchPayload, bytes32 payloadId) =
            createPayload(stakeManagerImpl, validatorShareImpl, depositManagerImpl);

        uint256 balanceStakeManager = maticToken.balanceOf(address(stakeManagerProxy));
        console.log("Initial StakeManager Matic balance: ", balanceStakeManager);
        assertNotEq(balanceStakeManager, 0);
        uint256 balanceDepositManager = maticToken.balanceOf(address(depositManagerProxy));
        console.log("Initial DepositManager Matic balance: ", balanceDepositManager);
        assertNotEq(balanceDepositManager, 0);

        vm.prank(gSafeAddress);
        (bool successSchedule, bytes memory dataSchedule) = address(timelock).call(scheduleBatchPayload);
        if (successSchedule == false) {
            assembly {
                revert(add(dataSchedule, 32), mload(dataSchedule))
            }
        }

        assertEq(successSchedule, true);
        assertEq(timelock.isOperation(payloadId), true);
        assertEq(timelock.isOperationPending(payloadId), true);

        vm.warp(block.timestamp + 172_800);

        assertEq(timelock.isOperationReady(payloadId), true);

        vm.prank(gSafeAddress);

        (bool successExecute, bytes memory dataExecute) = address(timelock).call(executeBatchPayload);
        if (successExecute == false) {
            assembly {
                revert(add(dataExecute, 32), mload(dataExecute))
            }
        }
        assertEq(successExecute, true);
        assertEq(timelock.isOperationDone(payloadId), true);

        // Check migrations happened
        assertEq(maticToken.balanceOf(address(stakeManagerProxy)), 0);
        assertEq(polToken.balanceOf(address(stakeManagerProxy)), balanceStakeManager);
        assertEq(maticToken.balanceOf(address(depositManagerProxy)), 0);
        assertEq(polToken.balanceOf(address(depositManagerProxy)), balanceDepositManager);

        // Check Registry values
        assertEq(registry.contractMap(keccak256("validatorShare")), address(validatorShareImpl));
        assertEq(registry.contractMap(keccak256("pol")), address(polToken));
        assertEq(registry.contractMap(keccak256("matic")), address(maticToken));
        assertEq(registry.contractMap(keccak256("polygonMigration")), migrationAddress);
        assertEq(registry.rootToChildToken(address(polToken)), nativeGasTokenAddress);
        assertEq(registry.childToRootToken(nativeGasTokenAddress), address(polToken));
        assertEq(registry.isERC721(address(polToken)), false);

        // Check Proxy implementation addresses
        assertEq(Proxy(payable(address(stakeManagerProxy))).implementation(), address(stakeManagerImpl));
        assertEq(Proxy(payable(address(depositManagerProxy))).implementation(), address(depositManagerImpl));
    }
}
