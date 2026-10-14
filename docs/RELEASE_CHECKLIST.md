# 墨契 Attune public release checklist

This checklist excludes signing and build configuration, which the maintainer has separately confirmed with Huawei. Package checks do not establish permission to use another project's branding or a hosted service.

## Project disclosures

- [x] Identify Jin Ye as the 墨契 Attune developer, without removing upstream attribution.
- [x] Link About directly to the project source and issue tracker.
- [x] Offer offline licenses/credits and the 墨契 Attune privacy notice in About.
- [x] Preserve pinned upstream revisions, AGPL text, third-party notices and original vendored license files.
- [x] Describe 墨契 Attune as independent and unofficial.
- [ ] Review the privacy notice whenever sync, logging, analytics, permissions or storage behavior changes.

## Questions for the Readest team

- [ ] Confirm expectations for the 墨契 Attune name and modified book icon. Provide the exact icon and screenshots; do not treat a lack of response as approval.
- [ ] Confirm supported third-party use of the production cloud API and public Supabase client configuration; ask whether a separate client registration/authentication flow is preferred.
- [ ] Discuss schema compatibility, tombstones, cursor pagination, font replicas, unknown-field preservation and upload ordering.
- [ ] Ask about polling frequency, quotas, retry/backoff expectations, client/version identification and API-change announcements.
- [ ] Agree on compatibility wording and where users should report 墨契 Attune versus service issues.

These are questions about branding and service arrangements, not a request to waive rights already granted by the applicable open-source licenses.

## Live compatibility acceptance

Use disposable accounts and books, not a personal library. Automated fixtures are useful but do not replace these checks.

- [ ] Test 墨契 Attune and an official Readest client against the same account in both directions.
- [ ] Test progress conflicts, rereading backwards, offline recovery and unresolved locators without silent overwrite.
- [ ] Test bookmark/highlight creation, simultaneous editing and deletion; preserve unsupported fields.
- [ ] Test fonts, interrupted uploads/downloads, quota failures, token refresh and category switches.
- [ ] Test account switching, disconnect and cloud removal without affecting the wrong account.
- [ ] Record app versions, upstream revisions, dates, expected outcomes and actual results. No claim of full live compatibility until these pass.

## GitHub release publication

- [ ] Tag the exact commit used for the binary and link it prominently in the release.
- [ ] Make corresponding source, vendored components and required scripts available for that version under the applicable licenses. A profile link alone is insufficient.
- [ ] Include release notes identifying modifications and known compatibility limits.
- [ ] Publish a SHA-256 checksum, device/OS requirements and installation/update instructions verified on a target device.
- [ ] Check release attachments and source archives for private credentials, personal books, logs and test-account data.
- [ ] Do not publish signing keys, keystores or passwords. Do not claim that the distributed package has been device-tested unless it has.

No GitHub publication, message to the Readest team, or live-cloud mutation is performed by completing this document.
