//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

library AccountingMath {
    uint256 internal constant _MAX_BUNDLER_REFUND_RATE = 8_000_000; // out of 10_000_000 = 80%
    uint256 internal constant _SOLVER_GAS_LIMIT_BUFFER_PERCENTAGE = 500_000; // out of 10_000_000 = 5%
    uint256 internal constant _SCALE = 10_000_000; // 10_000_000 / 10_000_000 = 100%
    uint256 internal constant _FIXED_GAS_OFFSET = 120_000;

    function withSurcharge(uint256 amount, uint256 surchargeRate) internal pure returns (uint256 adjustedAmount) {
        adjustedAmount = amount * (_SCALE + surchargeRate) / _SCALE;
    }

    function withoutSurcharge(uint256 amount, uint256 surchargeRate) internal pure returns (uint256 unadjustedAmount) {
        unadjustedAmount = amount * _SCALE / (_SCALE + surchargeRate);
    }

    function withSurcharges(
        uint256 amount,
        uint256 atlasSurchargeRate,
        uint256 bundlerSurchargeRate
    )
        internal
        pure
        returns (uint256 adjustedAmount)
    {
        adjustedAmount = amount * (_SCALE + atlasSurchargeRate + bundlerSurchargeRate) / _SCALE;
    }

    // gets the Atlas surcharge from an unadjusted amount
    function getSurcharge(
        uint256 unadjustedAmount,
        uint256 surchargeRate
    )
        internal
        pure
        returns (uint256 surchargeAmount)
    {
        surchargeAmount = unadjustedAmount * surchargeRate / _SCALE;
    }

    function getPortionFromTotalSurcharge(
        uint256 totalSurcharge,
        uint256 targetSurchargeRate,
        uint256 totalSurchargeRate
    )
        internal
        pure
        returns (uint256 surchargePortion)
    {
        surchargePortion = totalSurcharge * targetSurchargeRate / totalSurchargeRate;
    }

    // NOTE: This max should only be applied when there are no winning solvers.
    // Set to 80% of the metacall gas cost, because the remaining 20% can be collected through storage refunds.
    function maxBundlerRefund(uint256 metacallGasCost) internal pure returns (uint256 maxRefund) {
        maxRefund = metacallGasCost * _MAX_BUNDLER_REFUND_RATE / _SCALE;
    }

    function solverGasLimitScaledDown(
        uint256 solverOpGasLimit,
        uint256 dConfigGasLimit
    )
        internal
        pure
        returns (uint256 gasLimit)
    {
        gasLimit = (solverOpGasLimit < dConfigGasLimit ? solverOpGasLimit : dConfigGasLimit) * _SCALE
            / (_SCALE + _SOLVER_GAS_LIMIT_BUFFER_PERCENTAGE);
    }
}
