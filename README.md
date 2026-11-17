# Morpheus S3 C-1 — Foundry fork PoC

PoC for the Morpheus bug-bounty submission: **SessionRouter provider approval is not bound
to the user** (LumerinDiamond on Base). An approval signed for a victim can be used by any
address to open a session as themselves, and the provider is paid from the protocol funding
account at close.

## Run

```bash
forge install foundry-rs/forge-std
forge test
```

- `test_C1_approvalForVictimUsableByAttacker` — attacker opens a session with the victim's
  provider approval (Base fork, pinned block **58512580**). PASS.
- `test_C1_control_victimCanUseOwnApproval` — control: the victim's own approval works.
  PASS.
- Full suite: 9/9 PASS.

## Requirements

- Foundry (forge 1.9.0, solc 0.8.24)
- Network access to `https://base.publicnode.com` (fork at block 58512580)

## Target

- LumerinDiamond `0x6aBE1d282f72B474E54527D93b979A4f64d3030a` (Base)
- SessionRouter facet `0x3a3952f0E57b343F00b31F7dA039eF16389B7260`
- `openSession` / `_extractProviderApproval`

Read-only on mainnet; all tests run on a local mainnet fork. Nothing is executed against
mainnet or testnet contracts.
