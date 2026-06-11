// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./echidna/EchidnaCrownInvariants.sol";

contract EchidnaCrownInvariantsCompileTest is Test {
    function test_echidnaHarnessExposesCurrentInvariantProperties() public {
        EchidnaCrownInvariants harness = new EchidnaCrownInvariants();

        assertTrue(harness.echidna_I1_solvency(), "I1 property");
        assertTrue(harness.echidna_I2_burnBeforeWithdraw(), "I2 property");
        assertTrue(harness.echidna_I4_backingPerShare_monotonic(), "I4 property");
    }

    function test_echidnaHarnessI1PropertyDetectsForcedInsolvency() public {
        EchidnaCrownInvariants harness = new EchidnaCrownInvariants();

        vm.prank(harness.FORGE_BREAK_CALLER());
        harness.forge_breakI1Solvency();

        assertFalse(harness.echidna_I1_solvency(), "I1 must fail after forced insolvency");
    }

    function test_echidnaHarnessI2PropertyDetectsOutflowBeforeBurn() public {
        EchidnaCrownInvariants harness = new EchidnaCrownInvariants();

        vm.prank(harness.FORGE_BREAK_CALLER());
        harness.forge_breakI2BurnBeforeWithdraw();

        assertFalse(harness.echidna_I2_burnBeforeWithdraw(), "I2 must fail after outflow-before-burn");
    }

    function test_echidnaHarnessI4PropertyDetectsBackingPerShareDecrease() public {
        EchidnaCrownInvariants harness = new EchidnaCrownInvariants();

        vm.prank(harness.FORGE_BREAK_CALLER());
        harness.forge_breakI4BackingPerShare();

        assertFalse(harness.echidna_I4_backingPerShare_monotonic(), "I4 must fail after backing/share decrease");
    }
}
