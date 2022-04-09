// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IERC1155} from "openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC1155PresetMinterPauser} from "openzeppelin/contracts/token/ERC1155/presets/ERC1155PresetMinterPauser.sol";

import {DSTest} from "ds-test/test.sol";

import {Codex} from "fiat/Codex.sol";
import {wdiv, toInt256} from "fiat/utils/Math.sol";

import {DSToken} from "../utils/dapphub/DSToken.sol";
import {MockProvider} from "../utils/MockProvider.sol";
import {Caller} from "../utils/Caller.sol";

import {VaultFC} from "../../VaultFC.sol";

contract VaultFCTest is DSTest {
    VaultFC vault;

    MockProvider codex;
    MockProvider collybus;
    ERC1155PresetMinterPauser notional;
    Caller kakaroto;

    uint256 constant MAX_DECIMALS = 38; // ~type(int256).max ~= 1e18*1e18
    uint256 constant MAX_AMOUNT = 10**(MAX_DECIMALS);
    uint256 internal constant QUARTER = 86400 * 6 * 5 * 3;
    address internal me = address(this);

    address underlierToken;

    uint256 defaultMaturity = block.timestamp - (block.timestamp % QUARTER) + QUARTER;

    function _encodeERC1155Id(
        uint256 currencyId,
        uint256 maturity,
        uint256 assetType
    ) internal pure returns (uint256) {
        require(maturity <= type(uint40).max);

        return
            uint256(
                (bytes32(uint256(uint16(currencyId))) << 48) |
                    (bytes32(uint256(uint40(maturity))) << 8) |
                    bytes32(uint256(uint8(assetType)))
            );
    }

    function setUp() public {
        kakaroto = new Caller();
        codex = new MockProvider();
        collybus = new MockProvider();
        notional = new ERC1155PresetMinterPauser("");
        underlierToken = address(new DSToken(""));
        vault = new VaultFC(address(codex), address(collybus), address(notional), underlierToken, QUARTER, 1);
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function test_vaultType() public {
        assertEq(vault.vaultType(), bytes32("ERC1155:FC"));
    }

    function test_token() public {
        assertEq(address(vault.token()), address(notional));
    }

    function test_tokenScale() public {
        assertEq(vault.tokenScale(), 10**8);
    }

    function test_underlier() public {
        assertEq(address(vault.underlierToken()), underlierToken);
    }

    function underlierScale() public {
        assertEq(vault.underlierScale(), 10**8);
    }

    function test_setParam_not_authorized() public {
        (bool ok, ) = kakaroto.externalCall(
            address(vault),
            abi.encodeWithSelector(vault.setParam.selector, "collybus", me)
        );
        assertTrue(ok == false, "Cannot call guarded method before adding permissions");
    }

    function testFail_setParam_wrong_param() public {
        vault.setParam("something", me);
    }

    function testFail_set_collybus_when_locked() public {
        vault.lock();

        vault.setParam("collybus", me);
    }

    function test_set_collybus() public {
        vault.setParam("collybus", me);
        assertEq(address(vault.collybus()), me);
    }

    function test_enter() public {
        uint256 tokenId = _encodeERC1155Id(1, defaultMaturity, 1);
        notional.setApprovalForAll(address(vault), true);
        notional.mint(address(this), tokenId, 1, new bytes(0));

        vault.enter(tokenId, me, 1);
    }

    function testFail_enter_when_locked() public {
        vault.lock();

        uint256 tokenId = _encodeERC1155Id(1, defaultMaturity, 1);
        notional.setApprovalForAll(address(vault), true);
        notional.mint(address(this), tokenId, 1, new bytes(0));

        vault.enter(tokenId, me, 1);
    }

    function testFail_enter_when_wrong_currency() public {
        uint256 tokenId = _encodeERC1155Id(2, defaultMaturity, 1);
        notional.setApprovalForAll(address(vault), true);
        notional.mint(address(this), tokenId, 1, new bytes(0));

        vault.enter(tokenId, me, 1);
    }

    function testFail_enter_when_amount_overflow() public {
        uint256 amount = uint256(type(int256).max) + 1;

        uint256 tokenId = _encodeERC1155Id(1, defaultMaturity, 1);
        notional.setApprovalForAll(address(vault), true);
        notional.mint(address(this), tokenId, amount, new bytes(0));

        vault.enter(tokenId, me, amount);
    }

    function test_enter_transfersTokens_to_vault(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;
        if (owner == address(0)) return;

        uint256 tokenId = _encodeERC1155Id(1, defaultMaturity, 1);

        notional.setApprovalForAll(address(vault), true);
        notional.mint(address(this), tokenId, amount, new bytes(0));

        vault.enter(tokenId, owner, amount);

        assertEq(notional.balanceOf(address(this), tokenId), 0);
        assertEq(notional.balanceOf(address(vault), tokenId), amount);
    }

    function test_enter_calls_codex_modifyBalance(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;
        if (owner == address(0)) return;

        uint256 tokenId = _encodeERC1155Id(1, defaultMaturity, 1);

        notional.setApprovalForAll(address(vault), true);
        notional.mint(address(this), tokenId, amount, new bytes(0));

        vault.enter(tokenId, owner, amount);

        MockProvider.CallData memory cd = codex.getCallData(0);
        assertEq(cd.caller, address(vault));
        assertEq(cd.functionSelector, Codex.modifyBalance.selector);

        int256 wad = toInt256(wdiv(amount, 10**8));
        assertEq(
            keccak256(cd.data),
            keccak256(abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), tokenId, owner, wad))
        );
        emit log_bytes(cd.data);
        emit log_bytes(abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), tokenId, owner, wad));
    }

    function testFail_exit_when_wrong_currency() public {
        uint256 tokenId = _encodeERC1155Id(2, defaultMaturity, 1);

        vault.exit(tokenId, me, 1);
    }

    function testFail_exit_when_amount_overflow() public {
        uint256 amount = uint256(type(int256).max) + 1;

        uint256 tokenId = _encodeERC1155Id(1, defaultMaturity, 1);

        vault.exit(tokenId, me, amount);
    }

    function test_exit_transfers_tokens(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;
        if (owner == address(0)) return;

        uint256 tokenId = _encodeERC1155Id(1, defaultMaturity, 1);

        notional.setApprovalForAll(address(vault), true);
        notional.mint(address(this), tokenId, amount, new bytes(0));

        vault.enter(tokenId, me, amount);
        vault.exit(tokenId, owner, amount);

        assertEq(notional.balanceOf(owner, tokenId), amount);
        assertEq(notional.balanceOf(address(vault), tokenId), 0);
    }

    function test_exit_calls_codex_modifyBalance(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;
        if (owner == address(0)) return;

        uint256 tokenId = _encodeERC1155Id(1, defaultMaturity, 1);

        notional.setApprovalForAll(address(vault), true);
        notional.mint(address(this), tokenId, amount, new bytes(0));

        vault.enter(tokenId, me, amount);
        vault.exit(tokenId, owner, amount);

        MockProvider.CallData memory cd = codex.getCallData(1);
        assertEq(cd.caller, address(vault));
        assertEq(cd.functionSelector, Codex.modifyBalance.selector);

        int256 wad = toInt256(wdiv(amount, 10**8));

        assertEq(
            keccak256(cd.data),
            keccak256(
                abi.encodeWithSelector(
                    Codex.modifyBalance.selector,
                    address(vault),
                    tokenId,
                    address(this),
                    -int256(wad)
                )
            )
        );
        emit log_bytes(cd.data);
        emit log_bytes(
            abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), tokenId, address(this), -int256(wad))
        );
    }

    function test_maturity(uint8 times) public {
        uint256 tokenId = _encodeERC1155Id(1, block.timestamp + (QUARTER * times), 1);
        assertEq(vault.maturity(tokenId), block.timestamp + (QUARTER * times));
    }

    function testFail_fairPrice_when_wrong_currency() public view {
        uint256 tokenId = _encodeERC1155Id(2, defaultMaturity, 1);

        vault.fairPrice(tokenId, true, true);
    }
}
