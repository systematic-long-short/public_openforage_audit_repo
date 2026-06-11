#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
contract_root="$(cd -- "${script_dir}/.." && pwd)"
cd "${contract_root}"

: "${FOUNDRY_PROFILE:=deploy}"
export FOUNDRY_PROFILE

if [[ "${FOUNDRY_PROFILE}" != "deploy" ]]; then
  echo "Deploy.s.sol must run with FOUNDRY_PROFILE=deploy so implementation bytecode fits EIP-170" >&2
  exit 64
fi

required_env=(
  EXPECTED_CHAIN_ID
  USDC_ADDRESS
  BENEFICIARY
  FOUNDATION_PRIMARY
  FOUNDATION_BACKUP
  PROTOCOL_PRIMARY
  PROTOCOL_BACKUP
  LAUNCH_VOTING_DELEGATE
  KEEPER_ADDRESS
  CUSTODIAN_EXECUTOR
  COLD_ACCOUNT_ADDRESS
  HYPERLIQUID_SOURCE_ACCOUNT
  WITHDRAWAL_CHAIN_SELECTOR
  GUARDIAN_0
  GUARDIAN_1
  GUARDIAN_2
  GUARDIAN_3
  GUARDIAN_4
  GUARDIAN_5
  GUARDIAN_6
)

for name in "${required_env[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Deploy.s.sol requires ${name} to be set explicitly" >&2
    exit 64
  fi
done

exec forge script script/Deploy.s.sol:Deploy "$@"
