# MPP MES — Configuration Tool UI Specification

**Document:** MPP-MES-UISPEC-CONFIG-001
**Project:** Madison Precision Products MES Replacement
**Prepared By:** Blue Ridge Automation
**Version:** 1.0
**Date:** 2026-04-14

---

## Revision History

| Version | Date | Author | Change Summary |
|---|---|---|---|
| 1.0 | 2026-04-14 | Blue Ridge Automation | Initial Configuration Tool UI specification with 15 screen definitions, SP mappings, user actions, and fresh-implementation views |
| 1.1 | 2026-04-14 | Blue Ridge Automation | Validated against Claude Desktop memory files. Fixed: (1) Route Builder/BOM Editor now show three-state Draft/Published/Deprecated lifecycle; (2) Quality Spec Editor updated to match three-state pattern per feedback_three_state_versioning.md; (3) LocationTypeDefinition section corrected to read-only per feedback_readonly_type_tables.md — removed CRUD procs; (4) Updated proc count to 136. |
| 1.2 | 2026-05-05 | Blue Ridge Automation | Aligned with `MPP_MES_CONFIG_TOOL_FRONTEND_CONVENTIONS.md` v1.0. Two screens updated: (1) Eligibility Map (Screen 10) — removed "saves immediately" auto-save; cells now flip in `editDraft` and Save commits the diff; (2) Route Builder (Screen 9) — Move Up / Move Down arrow clicks now reorder `editDraft.steps[]` locally, committed only on Save. |

---

## Purpose

This document specifies the Ignition Perspective user interface for the **Configuration Tool** (Arc 1). It describes:

1. **What users see** — screen layout, components, and visual structure
2. **What users do** — actions, workflows, and interactions
3. **What stored procedures are called** — the API contract between UI and database
4. **What a fresh implementation renders** — initial state after deployment with seed data

This document complements `MPP_MES_PHASED_PLAN_CONFIG_TOOL.md` (which defines *what to build* in sequence) by specifying *exactly how each screen behaves*.

> **Cross-cutting conventions** (three-layer DB architecture, save semantics, versioning workflow refinements) are defined in `MPP_MES_CONFIG_TOOL_FRONTEND_CONVENTIONS.md`. Where this document and the conventions document disagree, the conventions document wins. Currently superseding two screens here: Eligibility Map (Screen 10) and Route Builder move-up / move-down behavior (Screen 9).

---

## Architecture Pattern

### Ignition Perspective + Named Queries

Every Configuration Tool screen follows the same pattern:

```
┌─────────────────────┐      ┌──────────────────────┐      ┌──────────────────┐
│  Perspective View   │ ───▶ │   Named Query        │ ───▶ │ Stored Procedure │
│  (UI Components)    │      │   (Gateway)          │      │ (SQL Server)     │
└─────────────────────┘      └──────────────────────┘      └──────────────────┘
         │                            │                            │
         │ User clicks "Save"         │ system.db.runNamedQuery()  │ EXEC Location.Location_Create
         │                            │ with parameters            │
         └────────────────────────────┴────────────────────────────┘
```

### Component Library

All screens use these standard Perspective components:

| Component | Usage |
|---|---|
| **Table** | List views with filtering, sorting, row selection |
| **Tree** | Plant hierarchy browser (recursive) |
| **Form** | Create/Edit modals with validation |
| **Dropdown** | Code table selections (loaded from `_List` procs) |
| **Button Group** | Up/Down arrows for sort ordering |
| **Popup/Modal** | Create, Edit, Confirm dialogs |
| **Tab Container** | Multi-section detail views |
| **Flex Container** | Master-detail layouts |

### Authentication Context

Every screen has access to:
- `session.props.auth.user.userName` — AD account
- `session.custom.appUserId` — resolved `Location.AppUser.Id` (set at login via `Location.AppUser_GetByAdAccount`)
- `session.custom.appUserDisplayName` — for UI display

Every mutating Named Query passes `@AppUserId` for audit attribution.

---

## Navigation Structure

The Configuration Tool lives under a `/config` navigation root, accessible only to users with Engineering or Admin Ignition roles.

```
/config
├── /users              → User Management
├── /audit-log          → Audit Log Browser
├── /failure-log        → Failure Log Browser
├── /plant              → Plant Hierarchy Browser + Details
├── /location-types     → Location Type Definition Browser
├── /reference-data     → Reference Data Manager (all code tables)
├── /items              → Item Master List + Editor
├── /routes             → Route Builder (linked from Item)
├── /operations         → Operation Template Library
├── /boms               → BOM Editor (linked from Item)
├── /quality-specs      → Quality Spec Library + Editor
├── /defect-codes       → Defect Code Manager
├── /downtime-codes     → Downtime Reason Code Manager
└── /shifts             → Shift Schedule Editor
```

---

## Screen Specifications

### 1. User Management (`/config/users`)

**Phase:** 1 (Identity & Audit Foundation)

**Purpose:** Manage MES user accounts that are linked to Active Directory identities.

#### What Users See

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ User Management                                              [+ Add User]    │
├──────────────────────────────────────────────────────────────────────────────┤
│ Filter: [Search by name/account___________] [☑ Show Deprecated]              │
├──────────────────────────────────────────────────────────────────────────────┤
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Display Name      │ AD Account       │ Clock#  │ Role      │ Status     │ │
│ ├───────────────────┼──────────────────┼─────────┼───────────┼────────────┤ │
│ │ System Bootstrap  │ system.bootstrap │ 0       │ Admin     │ Active     │ │
│ │ John Smith        │ jsmith@mpp.com   │ 1234    │ Engineer  │ Active     │ │
│ │ Maria Garcia      │ mgarcia@mpp.com  │ 5678    │ Operator  │ Active     │ │
│ │ (deprecated user) │ dold@mpp.com     │ 9999    │ Engineer  │ Deprecated │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│ [Click row to edit]                                                          │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Add/Edit User Modal:**
```
┌─────────────────────────────────────────┐
│ Add User                          [X]   │
├─────────────────────────────────────────┤
│ AD Account*:    [________________]      │
│ Display Name*:  [________________]      │
│ Clock Number*:  [____]                  │
│ Ignition Role*: [▼ Select Role   ]      │
│                 ├─ Admin                │
│                 ├─ Engineer             │
│                 ├─ Supervisor           │
│                 └─ Operator             │
│ Initial PIN:    [____] (optional)       │
│ Confirm PIN:    [____]                  │
├─────────────────────────────────────────┤
│                      [Cancel] [Save]    │
└─────────────────────────────────────────┘
```

#### User Actions

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load user list | Screen opens | `Location.AppUser_List` | `@IncludeDeprecated` (from checkbox) |
| Search/filter | Type in search box | Client-side filter on loaded data, or re-call `AppUser_List` |  |
| Open Add modal | Click [+ Add User] | — | — |
| Create user | Submit Add modal | `Location.AppUser_Create` | `@AdAccount, @DisplayName, @ClockNumber, @PinHash, @IgnitionRole, @AppUserId` |
| Open Edit modal | Click table row | `Location.AppUser_Get` | `@Id` |
| Update user | Submit Edit modal | `Location.AppUser_Update` | `@Id, @DisplayName, @ClockNumber, @IgnitionRole, @AppUserId` |
| Deprecate user | Click Deprecate in Edit modal | `Location.AppUser_Deprecate` | `@Id, @AppUserId` |
| Reset PIN | Click "Reset PIN" in Edit modal | `Location.AppUser_SetPin` | `@Id, @PinHash, @AppUserId` |

#### Fresh Implementation View

On a fresh deployment with only the bootstrap user:

| Display Name | AD Account | Clock# | Role | Status |
|---|---|---|---|---|
| System Bootstrap | system.bootstrap | 0 | Admin | Active |

The administrator's first action is to create their own real admin account, then create accounts for engineering staff.

---

### 2. Audit Log Browser (`/config/audit-log`)

**Phase:** 1 (Identity & Audit Foundation)

**Purpose:** View successful configuration changes for compliance and troubleshooting.

#### What Users See

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Audit Log — Configuration Changes                                            │
├──────────────────────────────────────────────────────────────────────────────┤
│ Filters:                                                                     │
│ Date Range: [2026-04-01] to [2026-04-14]  Entity: [▼ All        ]            │
│ User: [▼ All Users    ]                                                      │
│                                           [Apply Filters] [Clear]            │
├──────────────────────────────────────────────────────────────────────────────┤
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Timestamp           │ User          │ Entity   │ Event   │ Description  │ │
│ ├─────────────────────┼───────────────┼──────────┼─────────┼──────────────┤ │
│ │ 2026-04-14 09:32:15 │ J. Smith      │ Location │ Created │ Machine 7... │ │
│ │ 2026-04-14 09:30:02 │ J. Smith      │ Item     │ Updated │ 5G0 Front... │ │
│ │ 2026-04-14 09:28:45 │ M. Garcia     │ Route    │ Created │ Route for... │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│ ▼ Expanded Row Detail:                                                       │
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Entity: Location │ Id: 47 │ Event: Created                               │ │
│ │ Old Value: (null)                                                        │ │
│ │ New Value: {"Name":"Machine 7","Code":"DC-07","Tonnage":400}             │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### User Actions

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load log entries | Screen opens / Apply Filters | `Audit.ConfigLog_List` | `@StartDate, @EndDate, @LogEntityTypeCode, @AppUserId` |
| Populate entity dropdown | Screen opens | `Audit.LogEntityType_List` | — |
| Populate user dropdown | Screen opens | `Location.AppUser_List` | `@IncludeDeprecated = 1` |
| View entity history | Click "View Audit History" elsewhere | `Audit.ConfigLog_GetByEntity` | `@LogEntityTypeCode, @EntityId` |

#### Fresh Implementation View

Empty table with message: "No configuration changes recorded yet."

---

### 3. Failure Log Browser (`/config/failure-log`)

**Phase:** 1 (Identity & Audit Foundation)

**Purpose:** View rejected/failed operations for root-cause analysis and UX improvement.

#### What Users See

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Failure Log — Rejected Operations                                            │
├──────────────────────────────────────────────────────────────────────────────┤
│ Dashboard:  ┌─────────────────┐  ┌─────────────────┐                         │
│             │ Top Reasons (7d)│  │ Top Procs (7d)  │                         │
│             │ ─────────────── │  │ ─────────────── │                         │
│             │ Duplicate: 12   │  │ Item_Create: 8  │                         │
│             │ Required: 8     │  │ Route_Add: 5    │                         │
│             │ Invalid FK: 3   │  │ User_Update: 4  │                         │
│             └─────────────────┘  └─────────────────┘                         │
├──────────────────────────────────────────────────────────────────────────────┤
│ Filters:                                                                     │
│ Date Range: [2026-04-01] to [2026-04-14]  Procedure: [▼ All        ]         │
│ Entity: [▼ All        ]  User: [▼ All Users    ]                             │
│                                           [Apply Filters] [Clear]            │
├──────────────────────────────────────────────────────────────────────────────┤
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Timestamp           │ User      │ Procedure         │ Reason             │ │
│ ├─────────────────────┼───────────┼───────────────────┼────────────────────┤ │
│ │ 2026-04-14 09:35:22 │ J. Smith  │ Item_Create       │ Duplicate part#    │ │
│ │ 2026-04-14 09:33:10 │ J. Smith  │ Location_Deprecate│ Active dependents  │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│ ▼ Expanded Row Detail:                                                       │
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Attempted Parameters: {"PartNumber":"5G0","ItemTypeId":4,...}            │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### User Actions

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load failure entries | Screen opens / Apply Filters | `Audit.FailureLog_List` | `@StartDate, @EndDate, @LogEntityTypeCode, @AppUserId, @ProcedureName` |
| Load top reasons tile | Screen opens | `Audit.FailureLog_GetTopReasons` | `@StartDate, @EndDate, @LogEntityTypeCode` |
| Load top procs tile | Screen opens | `Audit.FailureLog_GetTopProcs` | `@StartDate, @EndDate` |

#### Fresh Implementation View

Empty table with message: "No failed operations recorded yet." Dashboard tiles show zeros.

---

### 4. Plant Hierarchy Browser (`/config/plant`)

**Phase:** 2 (Plant Model & Location Schema)

**Purpose:** Navigate and manage the ISA-95 plant hierarchy from Enterprise down to individual machines.

#### What Users See

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Plant Hierarchy                                                              │
├─────────────────────────────────┬────────────────────────────────────────────┤
│ TREE                            │ DETAILS PANEL                               │
│ ┌─────────────────────────────┐ │ ┌──────────────────────────────────────────┐│
│ │ 🏢 Madison Precision Prod.  │ │ │ Die Cast Machine #7                     ││
│ │ └─🏭 Madison Facility       │ │ │ ──────────────────────────────────────  ││
│ │   ├─📁 Die Cast         [+] │ │ │ Code: DC-07                             ││
│ │   │ ├─📁 DC Line 1      [+] │ │ │ Type: Cell → DieCastMachine             ││
│ │   │ │ ├─⚙️ DC Machine 1     │ │ │ Parent: DC Line 1                       ││
│ │   │ │ ├─⚙️ DC Machine 2     │ │ │ Description: 400-ton Buhler die cast    ││
│ │   │ │ ├─⚙️ DC Machine 3     │ │ │                                         ││
│ │   │ │ ├─⚙️ DC Machine 7 ◄── │ │ │ ATTRIBUTES                              ││
│ │   │ │ │   [▲][▼]            │ │ │ ──────────────────────────────────────  ││
│ │   │ │ └─⚙️ DC Machine 12    │ │ │ Tonnage*:          [400        ] tons   ││
│ │   │ └─📁 DC Line 2      [+] │ │ │ NumberOfCavities*: [2          ]        ││
│ │   ├─📁 Trim Shop        [+] │ │ │ RefCycleTimeSec:   [45.5       ] sec    ││
│ │   ├─📁 Machine Shop     [+] │ │ │                                         ││
│ │   ├─📁 Assembly         [+] │ │ │ ACTIONS                                 ││
│ │   └─📁 Support Areas    [+] │ │ │ [Save Changes] [View Audit History]     ││
│ │                             │ │ │ [Deprecate]                             ││
│ │ [+ Add Child]               │ │ └──────────────────────────────────────────┘│
│ └─────────────────────────────┘ │                                            │
├─────────────────────────────────┴────────────────────────────────────────────┤
│ Selected: DC Machine 7 │ Path: Madison > Madison Facility > Die Cast > ...   │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Add Location Modal:**
```
┌─────────────────────────────────────────┐
│ Add Location under "DC Line 1"    [X]   │
├─────────────────────────────────────────┤
│ Type Definition*: [▼ DieCastMachine  ]  │
│                   ├─ DieCastMachine     │
│                   ├─ Terminal           │
│                   └─ Scale              │
│ Name*:           [________________]     │
│ Code*:           [________]             │
│ Description:     [________________]     │
│                  [________________]     │
├─────────────────────────────────────────┤
│                      [Cancel] [Create]  │
└─────────────────────────────────────────┘
```

#### User Actions

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load full tree | Screen opens | `Location.Location_GetTree` | `@RootLocationId = 1` (Enterprise root) |
| Select node | Click tree node | `Location.Location_Get` | `@Id` |
| Load attributes | Node selected | `Location.LocationAttribute_GetByLocation` | `@LocationId` |
| Load attribute schema | Node selected | `Location.LocationAttributeDefinition_ListByDefinition` | `@LocationTypeDefinitionId` |
| Show breadcrumb | Node selected | `Location.Location_GetAncestors` | `@LocationId` |
| Move node up | Click [▲] | `Location.Location_MoveUp` | `@Id, @AppUserId` |
| Move node down | Click [▼] | `Location.Location_MoveDown` | `@Id, @AppUserId` |
| Open Add modal | Click [+ Add Child] | `Location.LocationTypeDefinition_List` | `@LocationTypeId` (filtered by valid child types) |
| Create location | Submit Add modal | `Location.Location_Create` | `@LocationTypeDefinitionId, @ParentLocationId, @Name, @Code, @Description, @AppUserId` |
| Save changes | Click [Save Changes] | `Location.Location_Update` | `@Id, @Name, @Code, @Description, @AppUserId` |
| Save attribute | Attribute field blur | `Location.LocationAttribute_Set` | `@LocationId, @LocationAttributeDefinitionId, @AttributeValue, @AppUserId` |
| Clear attribute | Clear non-required field | `Location.LocationAttribute_Clear` | `@LocationId, @LocationAttributeDefinitionId, @AppUserId` |
| Deprecate | Click [Deprecate] | `Location.Location_Deprecate` | `@Id, @AppUserId` |

#### Fresh Implementation View

After seed data load, the tree shows:
- 🏢 Madison Precision Products, Inc. (Enterprise)
  - 🏭 Madison Facility (Site)
    - 📁 Die Cast (Area)
      - 📁 DC Line 1 (WorkCenter)
        - ⚙️ DC Machine 1–7, 10, 12, 15 (Cells — machines from `machines.csv`)
    - 📁 Trim Shop (Area)
    - 📁 Machine Shop (Area)
    - 📁 Assembly (Area)
    - 📁 Support Areas (Area)
      - 📁 Production Control
      - 📁 Quality Control
      - 📁 Shipping
      - 📁 Receiving

---

### 5. Location Type Definition Browser (`/config/location-types`)

**Phase:** 2 (Plant Model & Location Schema)

**Purpose:** View the polymorphic location kinds (Terminal, DieCastMachine, etc.) and manage their attribute schemas. LocationType and LocationTypeDefinition are **seeded at deployment and read-only** — only the attribute definitions are editable.

#### What Users See

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Location Type Definitions                                                    │
├──────────────────────────────────────────────────────────────────────────────┤
│ Group by ISA-95 Tier: [▼ All Tiers    ]                                      │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│ ═══ CELL (ISA-95 Level 4) ═══════════════════════════════════════════════   │
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Code              │ Name                │ Icon                  │ Attrs │ │
│ ├───────────────────┼─────────────────────┼───────────────────────┼───────┤ │
│ │ Terminal          │ Terminal            │ material/computer     │ 3     │ │
│ │ DieCastMachine    │ Die Cast Machine    │ material/factory      │ 4     │ │
│ │ CNCMachine        │ CNC Machine         │ material/precision... │ 3     │ │
│ │ TrimPress         │ Trim Press          │ material/compress     │ 2     │ │
│ │ InventoryLocation │ Inventory Location  │ material/warehouse    │ 3     │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│ ═══ WORK CENTER (ISA-95 Level 3) ════════════════════════════════════════   │
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ ProductionLine    │ Production Line     │ material/conveyor     │ 0     │ │
│ │ InspectionLine    │ Inspection Line     │ material/search       │ 1     │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘

Expanded Kind: DieCastMachine
┌──────────────────────────────────────────────────────────────────────────────┐
│ Attributes for DieCastMachine                          [+ Add Attribute]     │
├──────────────────────────────────────────────────────────────────────────────┤
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │     │ Attribute        │ Data Type  │ Required │ UOM     │ Default      │ │
│ ├─────┼──────────────────┼────────────┼──────────┼─────────┼──────────────┤ │
│ │ ▲▼  │ Tonnage          │ DECIMAL    │ Yes      │ tons    │ —            │ │
│ │ ▲▼  │ NumberOfCavities │ INT        │ Yes      │ —       │ 1            │ │
│ │ ▲▼  │ RefCycleTimeSec  │ DECIMAL    │ No       │ seconds │ —            │ │
│ │ ▲▼  │ OeeTarget        │ DECIMAL    │ No       │ —       │ 0.85         │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### User Actions

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load definitions | Screen opens | `Location.LocationTypeDefinition_List` | `@LocationTypeId` (optional filter) |
| Load tiers dropdown | Screen opens | `Location.LocationType_List` | — |
| Expand definition | Click table row | `Location.LocationAttributeDefinition_ListByDefinition` | `@LocationTypeDefinitionId` |
| Add attribute | Submit Add Attribute modal | `Location.LocationAttributeDefinition_Create` | `@LocationTypeDefinitionId, @AttributeName, @DataType, @IsRequired, @DefaultValue, @Uom, @Description, @AppUserId` |
| Move attribute up | Click [▲] | `Location.LocationAttributeDefinition_MoveUp` | `@Id, @AppUserId` |
| Move attribute down | Click [▼] | `Location.LocationAttributeDefinition_MoveDown` | `@Id, @AppUserId` |
| Update attribute | Save edit | `Location.LocationAttributeDefinition_Update` | `@Id, @AttributeName, @DataType, @IsRequired, @DefaultValue, @Uom, @Description, @AppUserId` |
| Deprecate attribute | Click Deprecate | `Location.LocationAttributeDefinition_Deprecate` | `@Id, @AppUserId` |

> **Note:** LocationType and LocationTypeDefinition rows are seeded in the migration and cannot be created, updated, or deprecated via the UI. Only List and Get procs exist. To add a new location kind, modify the migration script and redeploy.

#### Fresh Implementation View

All 15 seeded definitions shown, grouped by tier. Clicking each shows its attribute schema (e.g., DieCastMachine shows Tonnage, NumberOfCavities, RefCycleTimeSec).

---

### 6. Reference Data Manager (`/config/reference-data`)

**Phase:** 3 (Reference Lookups)

**Purpose:** View and manage code tables. Read-only tables are view-only; mutable tables allow CRUD.

#### What Users See

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Reference Data Manager                                                       │
├──────────────────────────────────────────────────────────────────────────────┤
│ Select Table: [▼ Units of Measure (Parts.Uom)                              ] │
│               ├─── LOTS ───────────────────────────────────────────────────  │
│               │ LotOriginType (read-only)                                    │
│               │ LotStatusCode (read-only)                                    │
│               │ ContainerStatusCode (read-only)                              │
│               │ GenealogyRelationshipType (read-only)                        │
│               │ PrintReasonCode (read-only)                                  │
│               │ LabelTypeCode (read-only)                                    │
│               ├─── QUALITY ────────────────────────────────────────────────  │
│               │ InspectionResultCode (read-only)                             │
│               │ SampleTriggerCode (read-only)                                │
│               │ HoldTypeCode (read-only)                                     │
│               │ DispositionCode (read-only)                                  │
│               ├─── OEE ────────────────────────────────────────────────────  │
│               │ DowntimeSourceCode (read-only)                               │
│               ├─── WORKORDER ──────────────────────────────────────────────  │
│               │ OperationStatus (read-only)                                  │
│               │ WorkOrderStatus (read-only)                                  │
│               └─── PARTS ──────────────────────────────────────────────────  │
│                 Units of Measure (Parts.Uom)                                 │
│                 Item Types (Parts.ItemType)                                  │
│                 Data Collection Fields (Parts.DataCollectionField)           │
├──────────────────────────────────────────────────────────────────────────────┤
│ Units of Measure                                         [+ Add] (if mutable)│
├──────────────────────────────────────────────────────────────────────────────┤
│ [☑ Show Deprecated]                                                          │
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Code  │ Name             │ Description                      │ Status    │ │
│ ├───────┼──────────────────┼──────────────────────────────────┼───────────┤ │
│ │ EA    │ Each             │ Individual piece count           │ Active    │ │
│ │ LB    │ Pounds           │ Weight in US pounds              │ Active    │ │
│ │ KG    │ Kilograms        │ Weight in kilograms              │ Active    │ │
│ │ IN    │ Inches           │ Linear measurement               │ Active    │ │
│ │ MM    │ Millimeters      │ Linear measurement (metric)      │ Active    │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│ ℹ️ Mutable table — click row to edit, use [+ Add] to create new entries      │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### User Actions

**For read-only tables (13 tables):**

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load entries | Select table | `<Schema>.<Entity>_List` | — |
| View single | Click row (detail view, not edit) | `<Schema>.<Entity>_Get` | `@Id` |

**For mutable tables (Parts.Uom, Parts.ItemType, Parts.DataCollectionField):**

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load entries | Select table | `Parts.<Entity>_List` | `@IncludeDeprecated` |
| Create entry | Submit Add modal | `Parts.<Entity>_Create` | `@Code, @Name, @Description, @AppUserId` |
| Update entry | Submit Edit modal | `Parts.<Entity>_Update` | `@Id, @Name, @Description, @AppUserId` |
| Deprecate entry | Click Deprecate | `Parts.<Entity>_Deprecate` | `@Id, @AppUserId` |

#### Fresh Implementation View

All 16 code tables populated with seed data:
- **Parts.Uom:** EA, LB, KG, IN, MM, PCS, etc.
- **Parts.ItemType:** RawMaterial, Component, SubAssembly, FinishedGood, PassThrough
- **Parts.DataCollectionField:** CollectsDieInfo, CollectsCavityInfo, CollectsWeight, CollectsGoodCount, CollectsBadCount, RequiresMaterialVerification, RequiresSerialNumber
- **Lots.LotStatusCode:** Good, Hold, Scrap, Closed (with BlocksProduction flags)
- **Lots.LotOriginType:** Manufactured, Received, ReceivedOffsite
- etc.

---

### 7. Item Master List & Editor (`/config/items`)

**Phase:** 4 (Item Master & Container Config)

**Purpose:** Manage the master list of all MPP part numbers.

#### What Users See — List

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Item Master                                                  [+ New Item]    │
├──────────────────────────────────────────────────────────────────────────────┤
│ Filters:                                                                     │
│ Search: [________________] Type: [▼ All Types    ] [☑ Show Deprecated]       │
├──────────────────────────────────────────────────────────────────────────────┤
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Part Number  │ Description           │ Type         │ UOM │ Weight      │ │
│ ├──────────────┼───────────────────────┼──────────────┼─────┼─────────────┤ │
│ │ 5G0          │ 5G0 Front Cover       │ FinishedGood │ EA  │ 2.45 LB     │ │
│ │ 5G0-R        │ 5G0 Rear Cover        │ FinishedGood │ EA  │ 2.38 LB     │ │
│ │ 6B2          │ 6B2 Cam Holder        │ FinishedGood │ EA  │ 0.85 LB     │ │
│ │ PNA          │ PNA Mounting Pin      │ Component    │ EA  │ 0.02 LB     │ │
│ │ AL-380       │ Aluminum Alloy 380    │ RawMaterial  │ LB  │ —           │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│ [Click row to open Item Editor]                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### What Users See — Editor

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Item: 5G0 Front Cover                               [Save] [View Audit] [X]  │
├──────────────────────────────────────────────────────────────────────────────┤
│ BASIC INFO                              │ INVENTORY                          │
│ ─────────────                           │ ─────────────                      │
│ Part Number*:  [5G0            ] 🔒     │ Default Sub-Lot Qty: [24    ]      │
│ Item Type*:    [▼ FinishedGood ] 🔒     │ Max LOT Size:        [500   ]      │
│ Description*:  [5G0 Front Cover      ]  │ Unit Weight:         [2.45  ]      │
│ Macola Part#:  [5G0-MACOLA          ]   │ Weight UOM:          [▼ LB  ]      │
│ UOM*:          [▼ EA                 ]  │                                    │
├─────────────────────────────────────────┴────────────────────────────────────┤
│ ┌──────┬──────────────┬─────────┬───────────────┬───────────────┐            │
│ │ Tab: │ Container    │ Routes  │ Eligibility   │ BOMs          │            │
│ │      │ Config       │         │               │               │            │
│ └──────┴──────────────┴─────────┴───────────────┴───────────────┘            │
│                                                                              │
│ CONTAINER CONFIGURATION (for Finished Goods)                                 │
│ ─────────────────────────────────────────────                                │
│ Trays Per Container*:  [4     ]                                              │
│ Parts Per Tray*:       [12    ]                                              │
│ Serialized*:           [☑]                                                   │
│ Dunnage Code:          [RD-5G0F      ]                                       │
│ Customer Code:         [HONDA-5G0   ]                                        │
│ ─────────────────────────────────────────────                                │
│ Closure Method:        [▼ Not Set    ] ⚠️ OI-02 pending MPP validation       │
│ Target Weight:         [______] LB                                           │
│                                                                              │
│                                              [Save Container Config]         │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### User Actions

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load item list | Screen opens | `Parts.Item_List` | `@ItemTypeId, @SearchText, @IncludeDeprecated` |
| Load item types dropdown | Screen opens | `Parts.ItemType_List` | — |
| Open Item Editor | Click row | `Parts.Item_Get` | `@Id` |
| Load UOMs dropdown | Editor opens | `Parts.Uom_List` | — |
| Create item | Submit New Item modal | `Parts.Item_Create` | `@PartNumber, @ItemTypeId, @Description, @MacolaPartNumber, @DefaultSubLotQty, @MaxLotSize, @UomId, @UnitWeight, @WeightUomId, @AppUserId` |
| Update item | Click [Save] | `Parts.Item_Update` | `@Id, @Description, @MacolaPartNumber, @DefaultSubLotQty, @MaxLotSize, @UomId, @UnitWeight, @WeightUomId, @AppUserId` |
| Deprecate item | Click [Deprecate] | `Parts.Item_Deprecate` | `@Id, @AppUserId` |
| Load container config | Container tab opens | `Parts.ContainerConfig_GetByItem` | `@ItemId` |
| Create container config | Save new config | `Parts.ContainerConfig_Create` | `@ItemId, @TraysPerContainer, @PartsPerTray, @IsSerialized, @DunnageCode, @CustomerCode, @AppUserId` |
| Update container config | Save changes | `Parts.ContainerConfig_Update` | `@Id, @TraysPerContainer, @PartsPerTray, @IsSerialized, @DunnageCode, @CustomerCode, @AppUserId` |
| Deprecate container config | Click Deprecate | `Parts.ContainerConfig_Deprecate` | `@Id, @AppUserId` |

#### Fresh Implementation View

Empty item list with message: "No items configured. Click [+ New Item] to add your first part number."

**Note:** MPP must provide their parts-list export for bulk loading. Until then, items are added manually via the editor.

---

### 8. Operation Template Library (`/config/operations`)

**Phase:** 5 (Process Definition)

**Purpose:** Define reusable operation templates that route steps reference.

#### What Users See

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Operation Templates                                      [+ New Template]    │
├──────────────────────────────────────────────────────────────────────────────┤
│ Filter by Area: [▼ All Areas      ]  [☐ Show Deprecated]                     │
├──────────────────────────────────────────────────────────────────────────────┤
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Name                 │ Area         │ Version │ Fields │ Used In        │ │
│ ├──────────────────────┼──────────────┼─────────┼────────┼────────────────┤ │
│ │ Die Cast             │ Die Cast     │ v1      │ 4      │ 12 routes      │ │
│ │ Trim                 │ Trim Shop    │ v1      │ 2      │ 8 routes       │ │
│ │ CNC Machining        │ Machine Shop │ v2      │ 3      │ 15 routes      │ │
│ │ Assembly - Serialized│ Assembly     │ v1      │ 5      │ 4 routes       │ │
│ │ Pack & Ship          │ Shipping     │ v1      │ 2      │ 6 routes       │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘

Expanded Template: "Die Cast" (v1)
┌──────────────────────────────────────────────────────────────────────────────┐
│ Template: Die Cast                               [Edit] [New Version]        │
│ Area: Die Cast │ Version: 1 │ Created: 2026-04-10                            │
├──────────────────────────────────────────────────────────────────────────────┤
│ Data Collection Fields                                   [+ Add Field]       │
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Field Code            │ Field Name              │ Required │ [Remove]    │ │
│ ├───────────────────────┼─────────────────────────┼──────────┼─────────────┤ │
│ │ CollectsDieInfo       │ Collect Die Info        │ Yes      │ [X]         │ │
│ │ CollectsCavityInfo    │ Collect Cavity Info     │ Yes      │ [X]         │ │
│ │ CollectsWeight        │ Collect Weight          │ No       │ [X]         │ │
│ │ CollectsGoodCount     │ Collect Good Count      │ Yes      │ [X]         │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### User Actions

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load templates | Screen opens | `Parts.OperationTemplate_List` | `@AreaLocationId, @ActiveOnly` |
| Load areas dropdown | Screen opens | `Location.Location_GetDescendantsOfType` | `@LocationId = 1, @LocationTypeId = 2` (Areas) |
| Expand template | Click row | `Parts.OperationTemplateField_ListByTemplate` | `@OperationTemplateId` |
| Create template | Submit New Template modal | `Parts.OperationTemplate_Create` | `@Name, @AreaLocationId, @AppUserId` |
| Update template | Save edit | `Parts.OperationTemplate_Update` | `@Id, @Name, @AreaLocationId, @AppUserId` |
| Create new version | Click [New Version] | `Parts.OperationTemplate_CreateNewVersion` | `@ParentOperationTemplateId, @EffectiveFrom, @AppUserId` |
| Deprecate template | Click Deprecate | `Parts.OperationTemplate_Deprecate` | `@Id, @AppUserId` |
| Add field | Submit Add Field picker | `Parts.OperationTemplateField_Add` | `@OperationTemplateId, @DataCollectionFieldId, @IsRequired, @AppUserId` |
| Remove field | Click [X] on field row | `Parts.OperationTemplateField_Remove` | `@Id, @AppUserId` |
| Load field picker | [+ Add Field] clicked | `Parts.DataCollectionField_List` | — |

#### Fresh Implementation View

Empty template list with message: "No operation templates defined. Click [+ New Template] to define your first operation type."

---

### 9. Route Builder (`/config/routes`)

**Phase:** 5 (Process Definition)

**Purpose:** Define the sequence of operations for each item.

#### What Users See

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Route Builder                                                                │
├──────────────────────────────────────────────────────────────────────────────┤
│ Item: [▼ Select Item... ] or search: [5G0_________] [→]                      │
│ Selected: 5G0 Front Cover                                                    │
├─────────────────────────────────┬────────────────────────────────────────────┤
│ ROUTE VERSIONS                  │ ROUTE STEPS (v2)                  [Publish]│
│ ┌─────────────────────────────┐ │ ┌──────────────────────────────────────────┐│
│ │ Version │ Effective  │ Sts │ │ │ Seq │ Operation          │ Area    │ [+] ││
│ ├─────────┼────────────┼─────┤ │ ├─────┼────────────────────┼─────────┼─────┤│
│ │ v3 ◄    │ (draft)    │ Dft │ │ │ ▲▼  │ Die Cast           │ Die Cast│ [X] ││
│ │ v2      │ 2026-04-01 │ Pub │ │ │ ▲▼  │ Trim               │ Trim Shp│ [X] ││
│ │ v1      │ 2026-01-15 │ Dep │ │ │ ▲▼  │ CNC Machining      │ Mach Shp│ [X] ││
│ └─────────────────────────────┘ │ │ ▲▼  │ Assembly - Serial. │ Assembly│ [X] ││
│                                 │ │ ▲▼  │ Pack & Ship        │ Shipping│ [X] ││
│ [+ New Version]                 │ └──────────────────────────────────────────┘│
│                                 │                                            │
│                                 │ [+ Add Step]                               │
├─────────────────────────────────┴────────────────────────────────────────────┤
│ [Save Route] [View Audit History]                                            │
└──────────────────────────────────────────────────────────────────────────────┘

Add Step Modal:
┌─────────────────────────────────────────┐
│ Add Route Step                    [X]   │
├─────────────────────────────────────────┤
│ Operation Template*:                    │
│ [▼ Select Operation Template...      ]  │
│ ├─ Die Cast (Die Cast)                  │
│ ├─ Trim (Trim Shop)                     │
│ ├─ CNC Machining (Machine Shop)         │
│ ├─ Assembly - Serialized (Assembly)     │
│ └─ Pack & Ship (Shipping)               │
├─────────────────────────────────────────┤
│                      [Cancel] [Add]     │
└─────────────────────────────────────────┘
```

#### User Actions

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load item picker | Screen opens | `Parts.Item_List` | — |
| Lookup by part# | Enter part# and click [→] | `Parts.Item_GetByPartNumber` | `@PartNumber` |
| Load routes for item | Item selected | `Parts.RouteTemplate_ListByItem` | `@ItemId, @ActiveOnly` |
| Select route version | Click version row | `Parts.RouteStep_ListByRoute` | `@RouteTemplateId` |
| Create route | Click [+ New Route] (first route) | `Parts.RouteTemplate_Create` | `@ItemId, @Name, @EffectiveFrom, @AppUserId` |
| Create new version | Click [+ New Version] | `Parts.RouteTemplate_CreateNewVersion` | `@ParentRouteTemplateId, @EffectiveFrom, @AppUserId` |
| Publish route | Click [Publish] (on draft) | `Parts.RouteTemplate_Publish` | `@Id, @AppUserId` |
| Deprecate route | Click Deprecate (on published) | `Parts.RouteTemplate_Deprecate` | `@Id, @AppUserId` |
| Load operation dropdown | [+ Add Step] clicked | `Parts.OperationTemplate_List` | `@ActiveOnly = 1` |
| Add step | Submit Add Step modal | (none — appended to `editDraft.steps[]`) | — |
| Update step | Change operation on existing step | (none — mutates `editDraft.steps[i]`) | — |
| Move step up | Click [▲] | (none — reorders `editDraft.steps[]` locally) | — |
| Move step down | Click [▼] | (none — reorders `editDraft.steps[]` locally) | — |
| Remove step | Click [X] | (none — removes from `editDraft.steps[]`) | — |
| Save route | Click [Save Route] | `Parts.RouteStep_Replace` (or step-by-step `_Add` / `_Update` / `_Remove` / `_MoveUp` / `_MoveDown` per diff against `selected.steps`) | `@RouteTemplateId, @AppUserId, @StepsJson` (TBD per implementation) |

#### Fresh Implementation View

Item picker dropdown populated from Item Master. No routes exist until engineering creates them.

---

### 10. Eligibility Map Editor (`/config/eligibility`)

**Phase:** 5 (Process Definition)

**Purpose:** Configure which items can run on which machines.

#### What Users See

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Eligibility Map — Item × Location Matrix                                     │
├──────────────────────────────────────────────────────────────────────────────┤
│ Filter Items: [▼ FinishedGood      ] Filter Locations: [▼ Die Cast Area   ]  │
├──────────────────────────────────────────────────────────────────────────────┤
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │              │ DC-01 │ DC-02 │ DC-03 │ DC-07 │ DC-10 │ DC-12 │ DC-15    │ │
│ ├──────────────┼───────┼───────┼───────┼───────┼───────┼───────┼──────────┤ │
│ │ 5G0          │ ☑     │ ☑     │ ☑     │ ☑     │ ☐     │ ☑     │ ☐        │ │
│ │ 5G0-R        │ ☑     │ ☑     │ ☑     │ ☑     │ ☐     │ ☑     │ ☐        │ │
│ │ 6B2          │ ☐     │ ☐     │ ☐     │ ☐     │ ☑     │ ☐     │ ☑        │ │
│ │ 6MA          │ ☐     │ ☐     │ ☐     │ ☐     │ ☑     │ ☐     │ ☑        │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│ Click any cell to toggle eligibility in the draft. Save commits all changes. │
│                                                                              │
│                                            [Save] [Cancel] ● Unsaved changes │
└──────────────────────────────────────────────────────────────────────────────┘
```

> Per `MPP_MES_CONFIG_TOOL_FRONTEND_CONVENTIONS.md` §2: cell clicks update `editDraft` only. The Save button computes the diff against `selected` and calls `Parts.ItemLocation_Add` / `Parts.ItemLocation_Remove` per changed cell. No auto-save.

#### User Actions

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load items | Screen opens / filter change | `Parts.Item_List` | `@ItemTypeId` |
| Load locations | Screen opens / filter change | `Location.Location_GetDescendantsOfType` | `@LocationId, @LocationTypeId = 4` (Cells) |
| Load existing eligibility (row) | For each item in view | `Parts.ItemLocation_ListByItem` | `@ItemId` |
| Toggle cell | Click cell | (none — updates `editDraft` only) | — |
| Save changes | Click [Save] | `Parts.ItemLocation_Add` for newly-checked cells; `Parts.ItemLocation_Remove` for newly-unchecked cells | `@ItemId, @LocationId, @AppUserId` per call |
| Cancel changes | Click [Cancel] | (none — restores `editDraft` from `selected`) | — |

#### Fresh Implementation View

Empty matrix until Items are created in Phase 4 and machines are loaded from seed data.

---

### 11. BOM Editor (`/config/boms`)

**Phase:** 6 (BOM Management)

**Purpose:** Create and manage versioned bills of material for assembled products.

#### What Users See

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ BOM Editor                                                                   │
├──────────────────────────────────────────────────────────────────────────────┤
│ Parent Item: [▼ Select Item... ] or search: [5G0_________] [→]               │
│ Selected: 5G0 Front Cover Assembly                                           │
├─────────────────────────────────┬────────────────────────────────────────────┤
│ BOM VERSIONS                    │ COMPONENTS (v3)                   [Publish]│
│ ┌─────────────────────────────┐ │ ┌──────────────────────────────────────────┐│
│ │ Version │ Effective  │ Sts │ │ │     │ Part#    │ Description  │ Qty │ UOM││
│ ├─────────┼────────────┼─────┤ │ ├─────┼──────────┼──────────────┼─────┼────┤│
│ │ v3 ◄    │ (draft)    │ Dft │ │ │ ▲▼  │ 5G0      │ 5G0 Casting  │ 1   │ EA ││
│ │ v2      │ 2026-03-01 │ Pub │ │ │ ▲▼  │ PNA      │ Mounting Pin │ 2   │ EA ││
│ │ v1      │ 2026-01-15 │ Dep │ │ │ ▲▼  │ WAS-001  │ Flat Washer  │ 2   │ EA ││
│ └─────────────────────────────┘ │ └──────────────────────────────────────────┘│
│ [+ New Version]                 │                                            │
│                                 │ [+ Add Component]                          │
├─────────────────────────────────┴────────────────────────────────────────────┤
│ Where Used: This item is a component in: 5G0-ASM-FRONT, 5G0-ASM-KIT          │
└──────────────────────────────────────────────────────────────────────────────┘

Add Component Modal:
┌─────────────────────────────────────────┐
│ Add BOM Component                 [X]   │
├─────────────────────────────────────────┤
│ Component Item*: [Item Picker...]       │
│ Selected: PNA - Mounting Pin            │
│                                         │
│ Quantity Per*:   [2      ]              │
│ UOM*:            [▼ EA   ]              │
├─────────────────────────────────────────┤
│                      [Cancel] [Add]     │
└─────────────────────────────────────────┘
```

#### User Actions

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load parent items | Screen opens | `Parts.Item_List` | `@ItemTypeId = SubAssembly or FinishedGood` |
| Load BOM versions | Item selected | `Parts.Bom_ListByParentItem` | `@ParentItemId, @ActiveOnly` |
| Select BOM version | Click version row | `Parts.BomLine_ListByBom` | `@BomId` |
| View active BOM | Default load | `Parts.Bom_GetActiveForItem` | `@ParentItemId, @AsOfDate` |
| Create BOM | Click [+ New BOM] (first BOM) | `Parts.Bom_Create` | `@ParentItemId, @VersionNumber, @EffectiveFrom, @AppUserId` |
| Create new version | Click [+ New Version] | `Parts.Bom_CreateNewVersion` | `@ParentBomId, @EffectiveFrom, @AppUserId` |
| Publish BOM | Click [Publish] | `Parts.Bom_Publish` | `@Id, @AppUserId` |
| Deprecate BOM | Click Deprecate | `Parts.Bom_Deprecate` | `@Id, @AppUserId` |
| Add component | Submit Add Component modal | `Parts.BomLine_Add` | `@BomId, @ChildItemId, @QtyPer, @UomId, @AppUserId` |
| Update component | Edit qty/UOM inline | `Parts.BomLine_Update` | `@Id, @QtyPer, @UomId, @AppUserId` |
| Move component up | Click [▲] | `Parts.BomLine_MoveUp` | `@Id, @AppUserId` |
| Move component down | Click [▼] | `Parts.BomLine_MoveDown` | `@Id, @AppUserId` |
| Remove component | Click [X] | `Parts.BomLine_Remove` | `@Id, @AppUserId` |
| View where used | Click "Where Used" link | `Parts.Bom_WhereUsedByChildItem` | `@ChildItemId` |

#### Fresh Implementation View

Item picker populated. No BOMs exist until engineering creates them.

---

### 12. Quality Spec Library & Editor (`/config/quality-specs`)

**Phase:** 7 (Quality Configuration)

**Purpose:** Define versioned quality specifications with measurable attributes. Uses the three-state **Draft → Published → Deprecated** lifecycle (same as BOM and RouteTemplate).

#### What Users See

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Quality Specifications                                   [+ New Spec]        │
├──────────────────────────────────────────────────────────────────────────────┤
│ Filter: Item: [▼ All Items  ] Operation: [▼ All Operations  ]                │
├──────────────────────────────────────────────────────────────────────────────┤
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Spec Name             │ Item      │ Operation    │ Version │ Attributes │ │
│ ├───────────────────────┼───────────┼──────────────┼─────────┼────────────┤ │
│ │ 5G0 Dimensional       │ 5G0       │ CNC Machining│ v3 Dft  │ 5          │ │
│ │ 5G0 Visual            │ 5G0       │ Assembly     │ v1 Pub  │ 3          │ │
│ │ 6B2 Surface Finish    │ 6B2       │ Trim         │ v2 Pub  │ 4          │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘

Expanded Spec: "5G0 Dimensional"
┌──────────────────────────────────────────────────────────────────────────────┐
│ Spec: 5G0 Dimensional                                                        │
│ Item: 5G0 │ Operation: CNC Machining                                         │
├─────────────────────────────────┬────────────────────────────────────────────┤
│ SPEC VERSIONS                   │ ATTRIBUTES (v3)                   [Publish]│
│ ┌─────────────────────────────┐ │ ┌──────────────────────────────────────────┐│
│ │ Version │ Effective  │ Sts │ │ │     │ Attribute    │ Target│ Limits │ UOM││
│ ├─────────┼────────────┼─────┤ │ ├─────┼──────────────┼───────┼────────┼────┤│
│ │ v3 ◄    │ (draft)    │ Dft │ │ │ ▲▼  │ Surface Flat │ 0.002 │ ±0.001 │ IN ││
│ │ v2      │ 2026-03-01 │ Pub │ │ │ ▲▼  │ Bore Diamtr  │ 25.40 │ ±0.02  │ MM ││
│ │ v1      │ 2026-01-15 │ Dep │ │ │ ▲▼  │ Wall Thick   │ 3.5   │ ±0.2   │ MM ││
│ └─────────────────────────────┘ │ │ ▲▼  │ Porosity     │ Pass  │ —      │ —  ││
│                                 │ │ ▲▼  │ Edge Radius  │ 0.5   │ ±0.1   │ MM ││
│ [+ New Version]                 │ └──────────────────────────────────────────┘│
│                                 │                                            │
│                                 │ [+ Add Attribute]                          │
├─────────────────────────────────┴────────────────────────────────────────────┤
│ [View Audit History]                                                         │
└──────────────────────────────────────────────────────────────────────────────┘
└──────────────────────────────────────────────────────────────────────────────┘
```

#### User Actions

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load specs | Screen opens | `Quality.QualitySpec_List` | `@ItemId, @OperationTemplateId` |
| Filter by item | Select item dropdown | `Quality.QualitySpec_List` | `@ItemId` |
| Filter by operation | Select operation dropdown | `Quality.QualitySpec_List` | `@OperationTemplateId` |
| Expand spec | Click row | `Quality.QualitySpecVersion_ListBySpec` + `Quality.QualitySpecAttribute_ListByVersion` | `@QualitySpecId`, `@QualitySpecVersionId` |
| Create spec | Submit New Spec modal | `Quality.QualitySpec_Create` | `@Name, @ItemId, @OperationTemplateId, @AppUserId` |
| Create first version | After spec creation | `Quality.QualitySpecVersion_Create` | `@QualitySpecId, @VersionNumber = 1, @EffectiveFrom, @AppUserId` |
| Create new version | Click [+ New Version] | `Quality.QualitySpecVersion_CreateNewVersion` | `@ParentVersionId, @EffectiveFrom, @AppUserId` |
| Publish version | Click [Publish] (on draft) | `Quality.QualitySpecVersion_Publish` | `@Id, @AppUserId` |
| Deprecate version | Click Deprecate (on published) | `Quality.QualitySpecVersion_Deprecate` | `@Id, @AppUserId` |
| Deprecate spec | Click Deprecate (on spec header) | `Quality.QualitySpec_Deprecate` | `@Id, @AppUserId` |
| Add attribute | Submit Add Attribute modal | `Quality.QualitySpecAttribute_Add` | `@QualitySpecVersionId, @AttributeName, @DataType, @TargetValue, @LowerLimit, @UpperLimit, @UomId, @SampleTriggerCodeId, @AppUserId` |
| Update attribute | Edit inline | `Quality.QualitySpecAttribute_Update` | `@Id, @AttributeName, @DataType, @TargetValue, @LowerLimit, @UpperLimit, @UomId, @SampleTriggerCodeId, @AppUserId` |
| Move attribute up | Click [▲] | `Quality.QualitySpecAttribute_MoveUp` | `@Id, @AppUserId` |
| Move attribute down | Click [▼] | `Quality.QualitySpecAttribute_MoveDown` | `@Id, @AppUserId` |
| Remove attribute | Click [X] | `Quality.QualitySpecAttribute_Remove` | `@Id, @AppUserId` |
| Load sample triggers | Add/Edit attribute | `Quality.SampleTriggerCode_List` | — |
| Load UOMs | Add/Edit attribute | `Parts.Uom_List` | — |

#### Fresh Implementation View

Empty spec list. Quality specs are created per-item/per-operation as needed.

---

### 13. Defect Code Manager (`/config/defect-codes`)

**Phase:** 7 (Quality Configuration)

**Purpose:** Manage the ~145 defect codes used for reject entry.

#### What Users See

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Defect Codes                                        [+ Add Code] [Bulk Load] │
├──────────────────────────────────────────────────────────────────────────────┤
│ Filter: Area: [▼ All Areas    ] Search: [____________] [☐ Show Deprecated]   │
├──────────────────────────────────────────────────────────────────────────────┤
│ ═══ DIE CAST (56 codes) ═════════════════════════════════════════════════   │
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Code    │ Description                        │ IsExcused │ Status       │ │
│ ├─────────┼────────────────────────────────────┼───────────┼──────────────┤ │
│ │ 135     │ Porosity                           │ No        │ Active       │ │
│ │ 136     │ Cold Shut                          │ No        │ Active       │ │
│ │ 137     │ Flash                              │ Yes       │ Active       │ │
│ │ 138     │ Misrun                             │ No        │ Active       │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│ ═══ MACHINE SHOP (42 codes) ═════════════════════════════════════════════   │
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ 122     │ Dimensional (Out of Tolerance)     │ No        │ Active       │ │
│ │ 143     │ Surface Finish                     │ No        │ Active       │ │
│ │ 154     │ Tool Marks                         │ Yes       │ Active       │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### User Actions

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load defect codes | Screen opens | `Quality.DefectCode_List` | `@AreaLocationId, @IncludeDeprecated` |
| Load areas dropdown | Screen opens | `Location.Location_GetDescendantsOfType` | `@LocationId = 1, @LocationTypeId = 2` |
| Create code | Submit Add Code modal | `Quality.DefectCode_Create` | `@Code, @Description, @AreaLocationId, @IsExcused, @AppUserId` |
| Update code | Submit Edit modal | `Quality.DefectCode_Update` | `@Id, @Description, @AreaLocationId, @IsExcused, @AppUserId` |
| Deprecate code | Click Deprecate | `Quality.DefectCode_Deprecate` | `@Id, @AppUserId` |
| Bulk load | Upload CSV | `Quality.DefectCode_BulkLoadFromSeed` | `@CsvData, @AppUserId` |

#### Fresh Implementation View

After bulk loading `defect_codes.csv`: 153 codes displayed, grouped by 6 areas (Die Cast, Trim Shop, Machine Shop, Production Control, Quality Control, HSP).

---

### 14. Downtime Reason Code Manager (`/config/downtime-codes`)

**Phase:** 8 (Operations Reference Data)

**Purpose:** Manage the ~353 downtime reason codes.

#### What Users See

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Downtime Reason Codes                               [+ Add Code] [Bulk Load] │
├──────────────────────────────────────────────────────────────────────────────┤
│ Filter: Area: [▼ All       ] Type: [▼ All Types ] [☐ Show Deprecated]        │
│ ⚠️ 25 codes have no assigned Type — review required before go-live           │
├──────────────────────────────────────────────────────────────────────────────┤
│ ═══ DIE CAST — Equipment (34 codes) ═════════════════════════════════════   │
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Code    │ Description                │ Type       │ Excused │ Status    │ │
│ ├─────────┼────────────────────────────┼────────────┼─────────┼───────────┤ │
│ │ DC-001  │ Hydraulic Failure          │ Equipment  │ No      │ Active    │ │
│ │ DC-002  │ Die Stuck                  │ Equipment  │ No      │ Active    │ │
│ │ DC-003  │ Cooling System Fault       │ Equipment  │ No      │ Active    │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│ ═══ DIE CAST — Setup (12 codes) ═════════════════════════════════════════   │
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ DC-101  │ Die Change                 │ Setup      │ Yes     │ Active    │ │
│ │ DC-102  │ Warm-Up Shots              │ Setup      │ Yes     │ Active    │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│ ═══ ⚠️ UNASSIGNED TYPE (25 codes) ═══════════════════════════════════════   │
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ MS-999  │ Other Machine Shop Issue   │ [▼ Select ]│ —       │ Active    │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### User Actions

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load reason codes | Screen opens | `Oee.DowntimeReasonCode_List` | `@AreaLocationId, @DowntimeReasonTypeId, @IncludeDeprecated` |
| Load types dropdown | Screen opens | `Oee.DowntimeReasonType_List` | — |
| Load areas dropdown | Screen opens | `Location.Location_GetDescendantsOfType` | `@LocationId = 1, @LocationTypeId = 2` |
| Create code | Submit Add Code modal | `Oee.DowntimeReasonCode_Create` | `@Code, @Description, @AreaLocationId, @DowntimeReasonTypeId, @IsExcused, @AppUserId` |
| Update code | Submit Edit modal | `Oee.DowntimeReasonCode_Update` | `@Id, @Description, @AreaLocationId, @DowntimeReasonTypeId, @IsExcused, @AppUserId` |
| Deprecate code | Click Deprecate | `Oee.DowntimeReasonCode_Deprecate` | `@Id, @AppUserId` |
| Bulk load | Upload CSV | `Oee.DowntimeReasonCode_BulkLoadFromSeed` | `@CsvData, @AppUserId` |

#### Fresh Implementation View

After bulk loading `downtime_reason_codes.csv`: 353 codes displayed, grouped by area and type. Warning banner shows ~25 codes with empty TypeId per `parse_warnings.md`.

---

### 15. Shift Schedule Editor (`/config/shifts`)

**Phase:** 8 (Operations Reference Data)

**Purpose:** Define named shift schedules for OEE and production tracking.

#### What Users See

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Shift Schedules                                           [+ Add Schedule]   │
├──────────────────────────────────────────────────────────────────────────────┤
│ [☐ Show Deprecated]                                                          │
├──────────────────────────────────────────────────────────────────────────────┤
│ ┌──────────────────────────────────────────────────────────────────────────┐ │
│ │ Name           │ Start   │ End     │ Days              │ Effective      │ │
│ ├────────────────┼─────────┼─────────┼───────────────────┼────────────────┤ │
│ │ First Shift    │ 06:00   │ 14:00   │ Mon-Fri           │ 2026-01-01     │ │
│ │ Second Shift   │ 14:00   │ 22:00   │ Mon-Fri           │ 2026-01-01     │ │
│ │ Third Shift    │ 22:00   │ 06:00   │ Mon-Fri           │ 2026-01-01     │ │
│ │ Weekend OT     │ 06:00   │ 18:00   │ Sat-Sun           │ 2026-01-01     │ │
│ └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│ ┌─────────────────── Calendar Preview (Next 2 Weeks) ────────────────────┐  │
│ │ Mon 4/14  │ Tue 4/15  │ Wed 4/16  │ Thu 4/17  │ Fri 4/18  │ Sat 4/19 │  │
│ │ ▓ 1st     │ ▓ 1st     │ ▓ 1st     │ ▓ 1st     │ ▓ 1st     │ ▓ WkEnd │  │
│ │ ▓ 2nd     │ ▓ 2nd     │ ▓ 2nd     │ ▓ 2nd     │ ▓ 2nd     │          │  │
│ │ ▓ 3rd     │ ▓ 3rd     │ ▓ 3rd     │ ▓ 3rd     │ ▓ 3rd     │          │  │
│ └─────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### User Actions

| Action | Trigger | Stored Procedure | Parameters |
|---|---|---|---|
| Load schedules | Screen opens | `Oee.ShiftSchedule_List` | `@ActiveOnly` |
| Create schedule | Submit Add Schedule modal | `Oee.ShiftSchedule_Create` | `@Name, @StartTime, @EndTime, @DaysOfWeek, @EffectiveFrom, @AppUserId` |
| Update schedule | Submit Edit modal | `Oee.ShiftSchedule_Update` | `@Id, @Name, @StartTime, @EndTime, @DaysOfWeek, @EffectiveFrom, @AppUserId` |
| Deprecate schedule | Click Deprecate | `Oee.ShiftSchedule_Deprecate` | `@Id, @AppUserId` |

#### Fresh Implementation View

Empty schedule list. Engineering creates the 3-4 standard MPP shift patterns during initial setup.

---

## Stored Procedure Summary by Screen

| Screen | Read Procedures | Write Procedures |
|---|---|---|
| User Management | `AppUser_List`, `AppUser_Get`, `AppUser_GetByAdAccount` | `AppUser_Create`, `AppUser_Update`, `AppUser_Deprecate`, `AppUser_SetPin` |
| Audit Log Browser | `ConfigLog_List`, `ConfigLog_GetByEntity`, `LogEntityType_List`, `LogEventType_List`, `LogSeverity_List` | — |
| Failure Log Browser | `FailureLog_List`, `FailureLog_GetByEntity`, `FailureLog_GetTopReasons`, `FailureLog_GetTopProcs` | — |
| Plant Hierarchy | `Location_GetTree`, `Location_Get`, `Location_GetAncestors`, `Location_GetDescendantsOfType`, `LocationAttribute_GetByLocation`, `LocationAttributeDefinition_ListByDefinition`, `LocationTypeDefinition_List` | `Location_Create`, `Location_Update`, `Location_MoveUp`, `Location_MoveDown`, `Location_Deprecate`, `LocationAttribute_Set`, `LocationAttribute_Clear` |
| Location Type Definition Browser | `LocationType_List`, `LocationTypeDefinition_List`, `LocationTypeDefinition_Get`, `LocationAttributeDefinition_ListByDefinition`, `LocationAttributeDefinition_Get` | `LocationAttributeDefinition_Create`, `LocationAttributeDefinition_Update`, `LocationAttributeDefinition_MoveUp`, `LocationAttributeDefinition_MoveDown`, `LocationAttributeDefinition_Deprecate` |
| Reference Data Manager | `*_List`, `*_Get` for all 16 code tables | `Uom_Create/Update/Deprecate`, `ItemType_Create/Update/Deprecate`, `DataCollectionField_Create/Update/Deprecate` |
| Item Master | `Item_List`, `Item_Get`, `Item_GetByPartNumber`, `ItemType_List`, `Uom_List`, `ContainerConfig_GetByItem` | `Item_Create`, `Item_Update`, `Item_Deprecate`, `ContainerConfig_Create`, `ContainerConfig_Update`, `ContainerConfig_Deprecate` |
| Operation Template Library | `OperationTemplate_List`, `OperationTemplate_Get`, `OperationTemplateField_ListByTemplate`, `DataCollectionField_List`, `Location_GetDescendantsOfType` | `OperationTemplate_Create`, `OperationTemplate_Update`, `OperationTemplate_CreateNewVersion`, `OperationTemplate_Deprecate`, `OperationTemplateField_Add`, `OperationTemplateField_Remove` |
| Route Builder | `Item_List`, `Item_GetByPartNumber`, `RouteTemplate_ListByItem`, `RouteTemplate_Get`, `RouteTemplate_GetActiveForItem`, `RouteStep_ListByRoute`, `OperationTemplate_List` | `RouteTemplate_Create`, `RouteTemplate_CreateNewVersion`, `RouteTemplate_Deprecate`, `RouteTemplate_Publish`, `RouteStep_Add`, `RouteStep_Update`, `RouteStep_MoveUp`, `RouteStep_MoveDown`, `RouteStep_Remove` |
| Eligibility Map | `Item_List`, `Location_GetDescendantsOfType`, `ItemLocation_ListByItem`, `ItemLocation_ListByLocation` | `ItemLocation_Add`, `ItemLocation_Remove` |
| BOM Editor | `Item_List`, `Bom_ListByParentItem`, `Bom_Get`, `Bom_GetActiveForItem`, `BomLine_ListByBom`, `Bom_WhereUsedByChildItem`, `Uom_List` | `Bom_Create`, `Bom_CreateNewVersion`, `Bom_Deprecate`, `Bom_Publish`, `BomLine_Add`, `BomLine_Update`, `BomLine_MoveUp`, `BomLine_MoveDown`, `BomLine_Remove` |
| Quality Spec Editor | `QualitySpec_List`, `QualitySpec_Get`, `QualitySpecVersion_ListBySpec`, `QualitySpecVersion_GetActive`, `QualitySpecAttribute_ListByVersion`, `SampleTriggerCode_List`, `Uom_List` | `QualitySpec_Create`, `QualitySpec_Deprecate`, `QualitySpecVersion_Create`, `QualitySpecVersion_CreateNewVersion`, `QualitySpecVersion_Publish`, `QualitySpecVersion_Deprecate`, `QualitySpecAttribute_Add`, `QualitySpecAttribute_Update`, `QualitySpecAttribute_MoveUp`, `QualitySpecAttribute_MoveDown`, `QualitySpecAttribute_Remove` |
| Defect Code Manager | `DefectCode_List`, `DefectCode_Get`, `Location_GetDescendantsOfType` | `DefectCode_Create`, `DefectCode_Update`, `DefectCode_Deprecate`, `DefectCode_BulkLoadFromSeed` |
| Downtime Reason Code Manager | `DowntimeReasonCode_List`, `DowntimeReasonCode_Get`, `DowntimeReasonType_List`, `Location_GetDescendantsOfType` | `DowntimeReasonCode_Create`, `DowntimeReasonCode_Update`, `DowntimeReasonCode_Deprecate`, `DowntimeReasonCode_BulkLoadFromSeed` |
| Shift Schedule Editor | `ShiftSchedule_List`, `ShiftSchedule_Get` | `ShiftSchedule_Create`, `ShiftSchedule_Update`, `ShiftSchedule_Deprecate` |

---

## Implementation Dependencies

```
Phase 1: User Management, Audit Log Browser, Failure Log Browser
    │
    ▼
Phase 2: Plant Hierarchy Browser, Location Type Definition Browser
    │
    ▼
Phase 3: Reference Data Manager
    │
    ├──▶ Phase 4: Item Master List & Editor
    │         │
    │         ├──▶ Phase 5: Operation Template Library, Route Builder, Eligibility Map
    │         │
    │         └──▶ Phase 6: BOM Editor
    │
    └──▶ Phase 7: Quality Spec Editor, Defect Code Manager
         │
         ▼
    Phase 8: Downtime Reason Code Manager, Shift Schedule Editor
```

---

## Related Documents

| Document | Relevance |
|---|---|
| `MPP_MES_PHASED_PLAN_CONFIG_TOOL.md` | SP signatures, API layer design, conventions (v1.4) |
| `MPP_MES_DATA_MODEL.md` | Column-level table specifications |
| `MPP_MES_FDS.md` | Functional requirements with FDS-XX-NNN numbering |
| `MPP_MES_USER_JOURNEYS.md` | Arc 1 narrative that these screens implement |
| `sql/migrations/repeatable/` | All 136 implemented stored procedures |
| `sql/seeds/seed_locations.sql` | Dev seed data for plant hierarchy |
| `reference/seed_data/` | CSVs for defect codes, downtime codes, machines |
