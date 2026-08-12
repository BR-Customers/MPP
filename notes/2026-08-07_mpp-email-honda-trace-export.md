# DRAFT email to MPP — Honda-format trace export example request

> Draft only — not sent. Supports FAT-TRC-310. Review/edit recipient + wording before sending.
> Sending is Jacques's call (I don't send on your behalf).

**To:** (MPP contact — Quality / Honda liaison)
**From:** Blue Ridge Automation
**Subject:** MES traceability export — need a sample Honda-format output

---

Hi [name],

As we build out the LOT traceability screens in the new MES, we're ready to add the
**exportable trace output** — the report a user generates for a given part/LOT that walks the
full upstream/downstream genealogy (raw aluminum → die cast → trim → machining → assembly →
shipped container).

Before we lock the export format, we want it to match whatever Honda actually expects to
receive, rather than guessing. Could you send us:

1. **A real example** of a Honda-format traceability / genealogy export you've had to produce
   (PDF and/or CSV — whatever the actual deliverable is). A sanitized or historical one is fine.
2. **The trigger** — when/why Honda requests it (e.g. a containment/recall event, a routine
   audit), and the turnaround expected.
3. **Required fields & layout** — the exact columns/sections Honda wants (part number,
   description, MFG lot / serial, die rank / DC part level, dates, operator/station, defect and
   disposition data, etc.), and any mandated ordering or headers.
4. **Delivery format** — is this a printed PDF, a CSV/Excel upload into an Honda portal, or an
   EDI/AIM transmission?

An example document answers most of this faster than a spec back-and-forth. Once we have it,
we'll mirror the format directly off the MES genealogy data.

Thanks,
[Blue Ridge Automation]

---

**Why we're asking (internal note):** the on-screen Global Trace already composes the full
genealogy (`Lot_GetGenealogyTree` + production/consumption events); the missing piece is the
*export* in Honda's required shape. FDS-12-014 lists this as required; the format is unspecified
in our source docs. This request de-risks building the wrong export.
