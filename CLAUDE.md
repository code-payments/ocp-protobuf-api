# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains the Open Code Protocol (OCP) Protobuf API definitions for communication between OCP clients and server (Flipcash is the primary consumer). It uses Protocol Buffers to define gRPC services and generates client code for Go and TypeScript/JavaScript. The APIs target the Solana blockchain (Ed25519 keys, Solana transactions, the Code VM) and power payment, currency launchpad, and swap flows.

The repo is a pure schema repo: no application code, no tests. The deliverable of any change is a `.proto` edit plus the regenerated code under `generated/`, committed together.

## Build & Code Generation

All code generation runs in Docker containers. Docker is the only local prerequisite; `buf` and `protoc` are not installed on the dev machine and are not needed. Generated code is committed to the repository under `generated/`.

```bash
make                 # Clean, build Docker images, and generate all code
make go              # Generate Go code only
make protobuf-es     # Generate TypeScript/JavaScript code only
make clean           # Remove all generated code
make docker-build    # Build Docker images without generating
```

The Makefile is `.NOTPARALLEL`. The first run is slow because the images clone `googleapis` and `protoc-gen-validate` for the shared `validate/` and `google/` imports.

### How generation works
- `build/go/Dockerfile` + `build/go/generate.sh` - `golang:1.25` image. Runs `protoc -I/proto-common:/proto` per file with `--go_out`, `--go-grpc_out`, `--validate_out=lang=go` and `--experimental_allow_proto3_optional`. Output lands at `github.com/code-payments/ocp-protobuf-api/generated/go/...`; the Makefile flattens that path into `generated/go/`.
- `build/protobuf-es/Dockerfile` + `build/protobuf-es/generate.sh` - `node:16-bookworm` image with `protoc-gen-es` and `protoc-gen-connect-es` (`target=ts`). The script also rewrites `import ... "_pb.js"` to `"_pb"` and auto-creates `index.ts` barrels: one per directory (`export * from './ocp_x_service_pb'`) and a root one with namespaced exports (`export * as Balance from './balance/v1'`). New service directories are picked up automatically; nothing manual is needed.
- Each `.proto` yields three Go files (`*.pb.go`, `*_grpc.pb.go`, `*.pb.validate.go`) and two TS files (`*_pb.ts`, `*_connect.ts`).
- `proto/buf.gen.yaml` exists but is not used by the Makefile.

### Toolchain versions (relevant when regenerated output looks unexpectedly different)
- Go generators are pinned: `protoc-gen-go v1.28.1`, `protoc-gen-go-grpc v1.2.0`, `protoc-gen-validate v0.1.0` (plugin; the Go runtime dep in `go.mod` is v1.2.1). `protoc` comes from Debian bookworm (3.21.12). Both Dockerfiles carry a `todo` to version dependencies.
- The npm generators are **unpinned** (`npm i @bufbuild/protoc-gen-es @bufbuild/protoc-gen-connect-es ...`). Committed TS was generated with `protoc-gen-es v1.10.1` (the class-based Protobuf-ES v1 API, legacy `@bufbuild/connect` packages). If a fresh image build pulls a newer major and `make protobuf-es` rewrites every TS file, that is the cause, not your proto change. Don't commit sweeping unrelated TS churn without flagging it.
- After `make`, check `git status`: only the proto you touched and its corresponding `generated/go/<svc>/v1` and `generated/protobuf-es/<svc>/v1` files should differ (plus the root `index.ts` if you added a service).

### Linting / breaking-change detection
`proto/buf.yaml` configures FILE-level breaking detection and DEFAULT lint, but nothing in this repo (Makefile or CI) runs buf, and there is no `.github/` directory. Treat the config as a statement of intent:
- Never renumber, retype, or rename existing fields/messages/enums. Add new fields or new `oneof` variants instead.
- The existing protos deliberately deviate from DEFAULT lint in places (bare enum values like `OK = 0`, `oneof Filter`, PascalCase values in `CanWithdrawToAccountResponse.AccountType`). Match the surrounding style rather than "fixing" lint.
- Some misspelled identifiers are locked in by compatibility and must stay: `VerifiedLaunchapdCurrencyReserveStateBatch`, `AckMesssagesResponse`. Don't rename them.
- Breaking removals have been done when clients were coordinated (PR #66 removed the `GetBalance` RPC), but default to additive changes and confirm with the user before removing or renaming anything public.

## Project Structure

### Proto Definitions (`proto/`)
Service proto files are prefixed with `ocp_` to avoid filename conflicts with implementation apps (renamed in PR #51; keep this convention for new files). Sizes below are approximate and drift; `transaction` is by far the largest.

- `proto/common/v1/model.proto` - Shared types used across all services
- `proto/account/v1/ocp_account_service.proto` - Account service
- `proto/balance/v1/ocp_balance_service.proto` - Balance service (smallest)
- `proto/currency/v1/ocp_currency_service.proto` - Currency/launchpad service
- `proto/messaging/v1/ocp_messaging_service.proto` - Messaging service
- `proto/transaction/v1/ocp_transaction_service.proto` - Transaction/intent/swap service (~1400 lines, most complex)
- `proto/buf.yaml` - Buf config (FILE breaking, DEFAULT lint, deps on protoc-gen-validate and googleapis)

Every proto file header follows the same pattern; copy it for new files:
```proto
package ocp.<service>.v1;
option go_package = "github.com/code-payments/ocp-protobuf-api/generated/go/<service>/v1;<service>";
option java_package = "com.codeinc.gen.<service>.v1";
option objc_class_prefix = "CPB<Service>V1";   // transaction uses a legacy "APB" prefix; use CPB for new files
```

Import dependency graph (relevant when adding cross-service types):
- `common` depends on nothing (besides google/validate)
- `currency` imports `common`
- `transaction` imports `common`, `currency`
- `account` and `messaging` import `common`, `currency`, `transaction`
- `balance` imports `common`

### Generated Code
- `generated/go/` - Go code with gRPC stubs and `Validate()` methods (the pinned v0.1.0 plugin predates `ValidateAll()`, so don't expect it). Go module path `github.com/code-payments/ocp-protobuf-api`, packages `.../generated/go/<service>/v1`.
- `generated/protobuf-es/` - TypeScript via Protobuf-ES/Connect-ES with index.ts barrels

### Releases
Consumers pin by git tag (`vX.Y.Z`, semver, published as GitHub releases). `main` is often a few commits ahead of the latest tag (see `git tag`); tagging is a separate step from merging and is not something to do unprompted. Commits are squash-merged PRs whose titles carry the `(#N)` suffix, so the PR title is the commit message.

## Architecture

The proto comments are the contract (RPC semantics, action specs, Solana instruction lists, keepalive protocols); read them for detail. What follows is orientation.

| Service | RPCs | Purpose |
|---|---|---|
| `common` | none | Shared types: `AccountType`, Solana primitives (account IDs, ALTs, transactions, `SolanaTransactionConfig`), `IntentId`/`SwapId`, `ServerPing`/`ClientPong` keepalive, `Interval` |
| `account` | 2 | `IsOcpAccount`, `GetTokenAccountInfos` (balance source, management state, gift card state, cost basis) |
| `balance` | 1 | `GetBalances`: unauthenticated, many owners, per-mint breakdown |
| `currency` | 8 | Launchpad and market data: mints, historical/live data streams, `Launch`, `UpdateIcon`/`UpdateMetadata` (moderation attestations), `Discover`, `CheckAvailability` |
| `transaction` | 9 | Intents (`SubmitIntent`) and swaps (`StatefulSwap`, `StatelessSwap`), plus limits, withdrawals, gift card voiding |
| `messaging` | 5 | Rendezvous-key message streams for the bill give/grab scan-code flow |

Concepts worth knowing before editing:
- **Intents never exchange transactions.** Client and server exchange accounts and arguments, each builds the transaction (or Code VM instruction) independently, and the server verifies the client's signatures against its own. `SubmitIntent` is a bidirectional stream: `SubmitActions` → `ServerParameters` (one per action, in order) → `SubmitSignatures` → `Success`/`Error`. `Action.id` must equal its index. Every action and metadata carries its `mint`.
- **Intent metadata types** (`OpenAccounts`, `SendPublicPayment`, `ReceivePaymentsPublicly`, `PublicDistribution`, `SendPublicMultiPayment`) each document an exact "Action Spec" in their comments; keep it in sync with behaviour. Any intent may carry opaque `AppMetadata` (1–4096 bytes). "Indirect send" is the current term for what the account type and some fields still call remote send/gift card.
- **Verified data pattern:** `VerifiedCoreMintFiatExchangeRate` and `VerifiedLaunchpadCurrencyReserveState` are server-signed so clients can submit them back as proofs (`VerifiedExchangeData`). New price or state data that feeds payments should follow it.
- **Swaps sit outside the intent system** (submitted best effort, balances applied after finalization). Server parameter variants document their Solana instruction lists in comments; update those when a flow changes. Clients that request v1 transactions (`transaction_version`) must still handle v0 parameters.

## Conventions

- **Authentication**: requests include a `signature` field computed with the relevant private key over `serialize(request)` with the signature field(s) unset. Nearly every RPC follows this; new RPCs should too. Exceptions are public reads of blockchain/market state (`GetBalances`, every Currency RPC except `Launch`/`UpdateIcon`/`UpdateMetadata`, `CanWithdrawToAccount`) and `AckMessages`.
- **Validation**: `protoc-gen-validate` annotations everywhere: required messages, byte lengths, regex patterns (currency codes `^[a-z]{3,4}$`, printable-ASCII names, hex colors `^#[0-9a-fA-F]{6}$`), enum restrictions (`not_in: 0`, `in: [...]`, `defined_only`), `const` for hardcoded protocol values (21-day lock, 100 bps sell fee), repeated min/max items (1024 is the conventional "arbitrary" cap, commented as such). Add validation rules to all new fields.
- **Result enums**: responses define a nested `Result`/`Code` enum with `OK = 0` plus failure cases, rather than using gRPC status codes. Streaming responses use separate `Success` and `Error` messages with their own `Code` enums.
- **Streaming request/response oneofs**: bidirectional streams use a `oneof` with `option (validate.required) = true` to multiplex message types (request/pong, response/ping, initiate/submit_signatures, etc.).
- **Server-only vs client-only fields**: when a message is used in both directions, split them (e.g. `server_exchange_data` vs `client_exchange_data` in a `oneof`; `ReceivePaymentsPubliclyMetadata.exchange_data` is server-provided and rejected on submit). Document which side sets a field.
- **Versioning**: services live under `v1` packages; FILE-level breaking rules apply, so never renumber/retype existing fields. Add new fields or new oneof variants instead.
- **Quarks**: token amounts are in quarks (the smallest unit of a mint), as uint64. Fiat amounts are doubles; limits are floats.
- Proto comments are the source of truth for protocol flows (action specs, instruction formats, keepalive protocols). Keep them updated when changing behavior; downstream client and server implementations are written against them.

## Dependencies

Go 1.25, grpc v1.71, protobuf v1.36 (see `go.mod`). Buf config (`proto/buf.yaml`, `buf.lock`) pulls `protoc-gen-validate` and `googleapis` but nothing runs buf.
