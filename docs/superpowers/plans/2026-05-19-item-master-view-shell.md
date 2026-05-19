# Item Master — Phase 1 View Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Item Master Configuration Tool page (`/items`) as a fully laid-out visual surface backed by dummy data in `view.custom`, with each of the 5 tabs implemented as its own embedded sub-view and the `+Add Item` modal popup view scaffolded. No SQL, no NQs, no entity scripts — wire passes land in Phases 2–8.

**Architecture:**
- **Parent page view** `BlueRidge/Views/Parts/ItemMaster` holds all state on `view.custom` (items list, selected item bundle, editDraft, itemTypes, uoms, activeTab, mode, search, typeFilter).
- **5 embedded tab views** under `BlueRidge/Components/Parts/ItemMaster/<TabName>` — `ContainerConfig`, `Routes`, `Boms`, `QualitySpecs`, `Eligibility`. Each is always mounted; visibility gated by `position.display = "{view.custom.activeTab} = '<key>'"`. Each receives its data slice as `view.params.value` bidirectionally bound from the parent's `editDraft.<slice>`.
- **Item list row** `BlueRidge/Components/Parts/ItemMaster/ItemRow` — flex-repeater sub-view per item. Click fires page-scoped `itemRowClicked` message back to parent.
- **Add Item modal** `BlueRidge/Components/Popups/AddItem` — opened via `system.perspective.openPopup`. Owns its own `view.custom.draft`. Cancel + Create both close without writing in Phase 1.
- **Dirty indicator** on TitleBar via expression `if({view.custom.editDraft} != {view.custom.selected}, '● Unsaved changes', '')`.
- **Save / Deprecate / Create / New Version / Go to spec buttons** all fire `BlueRidge.Common.Notify.toast("Not wired yet", ..., "info", 5)` placeholders.

**Tech Stack:** Ignition 8.3 Perspective file-based project; `ia.container.flex`, `ia.display.flex-repeater`, `ia.display.view`, `ia.display.label`, `ia.input.text-field`, `ia.input.dropdown`, `ia.input.button`, `ia.input.checkbox`; bidirectional property bindings on `view.custom.editDraft.*`; page-scoped Perspective messaging for cross-view click events; existing `BlueRidge.Common.Notify.toast` for placeholder feedback.

**Reference patterns (already in the codebase):**
- Page layout + nav wiring: existing `BlueRidge/Views/Home/Landing` + `Views/Containers/Sidebar`
- Embedded sub-view with page-scoped message handoff: `Components/Audit/TopRow` consumed by `Audit/FailureLog`
- editDraft + dirty indicator + Cancel + Save: `Components/Popups/LocationTypeEditor`
- Project conventions: `ignition-context-pack/02_perspective_views.md` (bidirectional binding, embedded view params, `position.display` for conditional flex visibility), `07_conventions_and_antipatterns.md` (Save semantics, Mode discriminator, No drag-and-drop, Efficiency hierarchy)
- File-edit boundary: `feedback_ignition_view_edit_boundary.md` (new view files = safe to edit on disk; existing view.json = Designer)
- Scan after writes: `feedback_ignition_gateway_scan.md` (run `.\scan.ps1` at project root)

**Spec:** `docs/superpowers/specs/2026-05-19-item-master-view-shell-design.md`

---

## File Structure

**Modified (2 files):**
- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/page-config/config.json` — add `/items` route entry
- `.gitignore` — no change anticipated, but `thumbnail.png` writes are auto-generated and gitignored already

**Created (8 view directories, each holding `view.json` + `resource.json` = 16 files):**

```
ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/
  Views/Parts/ItemMaster/                      ← page view
    resource.json
    view.json
  Components/Parts/ItemMaster/
    ItemRow/                                   ← left-panel list row sub-view
      resource.json
      view.json
    ContainerConfig/                           ← tab 1
      resource.json
      view.json
    Routes/                                    ← tab 2
      resource.json
      view.json
    Boms/                                      ← tab 3
      resource.json
      view.json
    QualitySpecs/                              ← tab 4
      resource.json
      view.json
    Eligibility/                               ← tab 5
      resource.json
      view.json
  Components/Popups/AddItem/                   ← +Add Item modal
    resource.json
    view.json
```

Folder `Components/Parts/` needs to be created (it does not yet exist — only `Components/Parts/.gitkeep` is in `ReferenceData/`, not `Parts/`; we create the new tree on first write).

**Verified existing infrastructure (no edits required):**
- `views/BlueRidge/Views/Containers/Sidebar/view.json` — already has `RailItemParts` (line 73-131) navigating to `/items` AND `PartsCategory > NavItemItemMaster` (line 455-520) also navigating to `/items`
- `script-python/BlueRidge/Common/Nav/code.py` — `categoryForPath('/items')` already returns `'parts'` (line 21-22)
- `stylesheet/stylesheet.css` — every class the mockup references already exists: `psc-badge`, `psc-badge-published`, `psc-badge-draft`, `psc-badge-purple/orange/green/amber/violet`, `psc-field`, `psc-field-row`, `psc-field-label`, `psc-search-input`, `psc-select`, `psc-arrow-btn`, `psc-arrows`, `psc-tab-strip`, `psc-tab-item`, `psc-tab-item-active`, `psc-data-table`, `psc-tree-panel`, `psc-detail-panel`, `psc-modal`, `psc-modal-header`, `psc-modal-body`, `psc-modal-footer`, `psc-btn`, `psc-btn-primary`, `psc-btn-danger`, `psc-btn-sm`

---

## Conventions This Plan Follows

- **resource.json** for every view follows the project pattern (sample at `views/BlueRidge/Views/Quality/DefectCodes/resource.json`):
  ```json
  {
    "scope": "G",
    "version": 1,
    "restricted": false,
    "overridable": true,
    "files": ["view.json"],
    "attributes": {
      "lastModification": {
        "actor": "Jacques Potgieter",
        "timestamp": "2026-05-19T12:00:00Z"
      }
    }
  }
  ```
  Use the same actor + a current ISO timestamp on every new resource.json.

- **view.json root** is always `ia.container.flex` with `meta.name: "root"` (never anything else; binding paths assume `root`).

- **Style class references** drop the `psc-` prefix in `style.classes` (Perspective auto-prepends it). So `"style": {"classes": "badge badge-published"}` renders `<div class="psc-badge psc-badge-published">`.

- **Designer GSON escapes** `=`, `'`, `<`, `>`, `&` as 6-char unicode literals (`=`, `'`, `<`, `>`, `&`). When writing view.json content from outside Designer, **use the literal characters** — Designer will rewrite them on next save anyway, and the parser treats both forms identically. Existing files have the escape form because Designer wrote them; that's fine.

- **scan.ps1** must be run at project root after writing any new Ignition resource. Without it, the Gateway won't see the new files and Designer pulls return stale.

- **Commit messages** follow project convention: `feat(item-master): <one-liner>` or `docs(item-master): ...` etc. Omit any `Co-Authored-By: Claude` trailer per `feedback_no_claude_coauthor.md`.

---

## Task 1: Add `/items` page route

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/page-config/config.json`

- [ ] **Step 1: Read current page-config**

Run:
```
Read ignition/projects/MPP_Config/com.inductiveautomation.perspective/page-config/config.json
```
Expected: existing `pages` object with `/`, `/audit-log`, `/defect-codes`, `/downtime-codes`, `/failure-log`, `/plant`, `/quality-specs` (alphabetical except `/`).

- [ ] **Step 2: Add `/items` entry**

Use the Edit tool to insert a new entry between `/failure-log` and `/plant` (keeps alphabetical order):

```
old_string:     "/failure-log": {
      "title": "Failure Log",
      "viewPath": "BlueRidge/Views/Audit/FailureLog"
    },
    "/plant": {

new_string:     "/failure-log": {
      "title": "Failure Log",
      "viewPath": "BlueRidge/Views/Audit/FailureLog"
    },
    "/items": {
      "title": "Item Master",
      "viewPath": "BlueRidge/Views/Parts/ItemMaster"
    },
    "/plant": {
```

- [ ] **Step 3: Scan**

Run from project root:
```powershell
.\scan.ps1
```

Expected: HTTP 200 response. The page-config change alone won't render anything yet (the view doesn't exist) but the scan should not error on the config file.

- [ ] **Step 4: Verify**

Open a browser to the Configuration Tool. Navigating to `/items` will currently 404 (view doesn't exist) — that's expected at this point. The point of this step is to confirm scan accepted the config.

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/page-config/config.json
git commit -m "feat(item-master): register /items page route"
```

---

## Task 2: ItemMaster page view — shell with dummy state

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/resource.json`
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json`

This task creates the page view with all `view.custom` dummy data, the title bar, and a placeholder body that says "Item Master shell — Phase 1 build in progress." Subsequent tasks replace the placeholder with the real layout.

- [ ] **Step 1: Write resource.json**

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/resource.json
```

Content:
```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": ["view.json"],
  "attributes": {
    "lastModification": {
      "actor": "Jacques Potgieter",
      "timestamp": "2026-05-19T12:00:00Z"
    }
  }
}
```

- [ ] **Step 2: Write view.json**

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json
```

Content:
```json
{
  "custom": {
    "search": "",
    "typeFilter": "All Types",
    "activeTab": "containerConfig",
    "mode": "update",
    "items": [
      {"id": 1, "partNumber": "5G0",     "description": "Front Cover Assy",    "itemTypeName": "Finished Good", "typeBadge": "FG",   "isDraft": false},
      {"id": 2, "partNumber": "5G0-C",   "description": "Front Cover Casting", "itemTypeName": "Component",     "typeBadge": "COMP", "isDraft": false},
      {"id": 3, "partNumber": "PNA",     "description": "Mounting Pin",        "itemTypeName": "Component",     "typeBadge": "COMP", "isDraft": false},
      {"id": 4, "partNumber": "6MA-HSG", "description": "Cam Holder Housing",  "itemTypeName": "Pass-Through",  "typeBadge": "PT",   "isDraft": true},
      {"id": 5, "partNumber": "RPY",     "description": "Assembly Set",        "itemTypeName": "Finished Good", "typeBadge": "FG",   "isDraft": false}
    ],
    "itemTypes": ["Raw Material", "Component", "Sub-Assembly", "Finished Good", "Pass-Through"],
    "uoms": ["EA", "LB", "KG"],
    "selected": {
      "meta": {
        "Id": 1,
        "PartNumber": "5G0",
        "Description": "5G0 Front Cover Assembly",
        "ItemTypeName": "Finished Good",
        "UomCode": "EA",
        "MacolaPartNumber": "5G0-FC-001",
        "UnitWeight": 3.25,
        "WeightUomCode": "LB",
        "DefaultSubLotQty": 24,
        "PartsPerBasket": 100,
        "CountryOfOrigin": "US",
        "MaxParts": 500
      },
      "containerConfig": {
        "TraysPerContainer": 4,
        "PartsPerTray": 12,
        "IsSerialized": true,
        "ClosureMethod": "ByCount",
        "TargetWeight": null,
        "DunnageCode": "RD-5G0F",
        "CustomerCode": "HONDA-5G0"
      },
      "routes": {
        "publishedVersion": 2,
        "effectiveFrom": "2026-01-15",
        "steps": [
          {"seq": 1, "areaName": "Die Cast",     "templateLabel": "DC-5G0 v1 — Die Cast 5G0 Front Cover",   "isRequired": true, "dataFields": "DieInfo, CavityInfo, Weight, GoodCount, BadCount"},
          {"seq": 2, "areaName": "Trim Shop",    "templateLabel": "TRIM-5G0 v1 — Trim 5G0 Front Cover",     "isRequired": true, "dataFields": "Weight, GoodCount, BadCount"},
          {"seq": 3, "areaName": "Machine Shop", "templateLabel": "CNC-5G0 v1 — CNC Machining 5G0",         "isRequired": true, "dataFields": "GoodCount, BadCount"},
          {"seq": 4, "areaName": "Prod Control", "templateLabel": "ASSY-FRONT v1 — Assembly Front Cover",   "isRequired": true, "dataFields": "SerialNumber, MaterialVerification, GoodCount, BadCount"}
        ]
      },
      "boms": {
        "publishedVersion": 1,
        "effectiveFrom": "2026-01-15",
        "lines": [
          {"seq": 1, "componentName": "Front Cover Casting", "partNumber": "5G0-C", "qtyPer": 1, "uom": "EA"},
          {"seq": 2, "componentName": "Mounting Pin",        "partNumber": "PNA",   "qtyPer": 2, "uom": "EA"}
        ]
      },
      "qualitySpecs": [
        {"specName": "5G0 Dimensional Spec",  "activeVersion": "v2", "statusLabel": "Active"},
        {"specName": "5G0 Visual Inspection", "activeVersion": "v1", "statusLabel": "Active"}
      ],
      "eligibility": {
        "selectedArea": "Die Cast",
        "rows": [
          {"machineName": "DC Machine #3",  "code": "DC-003", "tonnage": "400 tons", "eligible": true},
          {"machineName": "DC Machine #7",  "code": "DC-007", "tonnage": "400 tons", "eligible": true},
          {"machineName": "DC Machine #12", "code": "DC-012", "tonnage": "400 tons", "eligible": true},
          {"machineName": "DC Machine #15", "code": "DC-015", "tonnage": "250 tons", "eligible": false}
        ]
      }
    },
    "editDraft": {
      "meta": {
        "Id": 1,
        "PartNumber": "5G0",
        "Description": "5G0 Front Cover Assembly",
        "ItemTypeName": "Finished Good",
        "UomCode": "EA",
        "MacolaPartNumber": "5G0-FC-001",
        "UnitWeight": 3.25,
        "WeightUomCode": "LB",
        "DefaultSubLotQty": 24,
        "PartsPerBasket": 100,
        "CountryOfOrigin": "US",
        "MaxParts": 500
      },
      "containerConfig": {
        "TraysPerContainer": 4,
        "PartsPerTray": 12,
        "IsSerialized": true,
        "ClosureMethod": "ByCount",
        "TargetWeight": null,
        "DunnageCode": "RD-5G0F",
        "CustomerCode": "HONDA-5G0"
      },
      "routes": {
        "publishedVersion": 2,
        "effectiveFrom": "2026-01-15",
        "steps": [
          {"seq": 1, "areaName": "Die Cast",     "templateLabel": "DC-5G0 v1 — Die Cast 5G0 Front Cover",   "isRequired": true, "dataFields": "DieInfo, CavityInfo, Weight, GoodCount, BadCount"},
          {"seq": 2, "areaName": "Trim Shop",    "templateLabel": "TRIM-5G0 v1 — Trim 5G0 Front Cover",     "isRequired": true, "dataFields": "Weight, GoodCount, BadCount"},
          {"seq": 3, "areaName": "Machine Shop", "templateLabel": "CNC-5G0 v1 — CNC Machining 5G0",         "isRequired": true, "dataFields": "GoodCount, BadCount"},
          {"seq": 4, "areaName": "Prod Control", "templateLabel": "ASSY-FRONT v1 — Assembly Front Cover",   "isRequired": true, "dataFields": "SerialNumber, MaterialVerification, GoodCount, BadCount"}
        ]
      },
      "boms": {
        "publishedVersion": 1,
        "effectiveFrom": "2026-01-15",
        "lines": [
          {"seq": 1, "componentName": "Front Cover Casting", "partNumber": "5G0-C", "qtyPer": 1, "uom": "EA"},
          {"seq": 2, "componentName": "Mounting Pin",        "partNumber": "PNA",   "qtyPer": 2, "uom": "EA"}
        ]
      },
      "qualitySpecs": [
        {"specName": "5G0 Dimensional Spec",  "activeVersion": "v2", "statusLabel": "Active"},
        {"specName": "5G0 Visual Inspection", "activeVersion": "v1", "statusLabel": "Active"}
      ],
      "eligibility": {
        "selectedArea": "Die Cast",
        "rows": [
          {"machineName": "DC Machine #3",  "code": "DC-003", "tonnage": "400 tons", "eligible": true},
          {"machineName": "DC Machine #7",  "code": "DC-007", "tonnage": "400 tons", "eligible": true},
          {"machineName": "DC Machine #12", "code": "DC-012", "tonnage": "400 tons", "eligible": true},
          {"machineName": "DC Machine #15", "code": "DC-015", "tonnage": "250 tons", "eligible": false}
        ]
      }
    }
  },
  "params": {},
  "props": {
    "defaultSize": {
      "width": 1280,
      "height": 720
    }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": {"name": "root"},
    "props": {
      "direction": "column",
      "style": {"classes": "canvas"}
    },
    "children": [
      {
        "type": "ia.container.flex",
        "meta": {"name": "TitleBar"},
        "position": {"basis": "auto", "shrink": 0},
        "props": {
          "direction": "row",
          "alignItems": "center",
          "style": {
            "padding": "8px 16px",
            "borderBottom": "1px solid var(--mpp-border-subtle)",
            "background": "var(--mpp-surface-card)",
            "gap": "12px"
          }
        },
        "children": [
          {
            "type": "ia.display.label",
            "meta": {"name": "LabelTitle"},
            "position": {"basis": "auto"},
            "props": {
              "text": "Item Master",
              "style": {"fontSize": "15px", "fontWeight": "600"}
            }
          },
          {
            "type": "ia.display.label",
            "meta": {"name": "LabelDirty"},
            "position": {"basis": "auto"},
            "propConfig": {
              "props.text": {
                "binding": {
                  "type": "expr",
                  "config": {
                    "expression": "if({view.custom.editDraft} != {view.custom.selected}, '● Unsaved changes', '')"
                  }
                }
              }
            },
            "props": {
              "style": {
                "fontSize": "12px",
                "color": "var(--mpp-state-warn-fg)",
                "fontStyle": "italic"
              }
            }
          },
          {
            "type": "ia.container.flex",
            "meta": {"name": "TitleSpacer"},
            "position": {"grow": 1},
            "props": {}
          },
          {
            "type": "ia.input.button",
            "meta": {"name": "BtnAddItem"},
            "position": {"basis": "auto"},
            "props": {
              "text": "+ Add Item",
              "style": {"classes": "btn btn-primary"}
            }
          }
        ]
      },
      {
        "type": "ia.display.label",
        "meta": {"name": "PlaceholderBody"},
        "position": {"grow": 1, "basis": "0"},
        "props": {
          "text": "Item Master shell — Phase 1 build in progress.",
          "style": {
            "padding": "32px",
            "color": "var(--mpp-text-muted)",
            "fontStyle": "italic"
          }
        }
      }
    ]
  }
}
```

- [ ] **Step 3: Scan**

```powershell
.\scan.ps1
```
Expected: HTTP 200.

- [ ] **Step 4: Browser verification**

Open the Configuration Tool. Click the sidebar's **Parts** rail icon, then **Item Master**. Page should load with:
- Title bar at top showing "Item Master" + (no dirty indicator since editDraft == selected)
- "+ Add Item" button on the right
- Italic placeholder text "Item Master shell — Phase 1 build in progress." below

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/
git commit -m "feat(item-master): page shell + dummy view.custom state"
```

---

## Task 3: ItemRow sub-view + LeftPanel with item list

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ItemRow/resource.json`
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ItemRow/view.json`
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json` (replace placeholder body with split layout + LeftPanel)

This task introduces the row sub-view used by the FlexRepeater, then replaces the page placeholder with the real Main split (LeftPanel + a temporary placeholder for the right detail area, which Task 4 fills in).

- [ ] **Step 1: Create ItemRow resource.json**

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ItemRow/resource.json
```

Content:
```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": ["view.json"],
  "attributes": {
    "lastModification": {
      "actor": "Jacques Potgieter",
      "timestamp": "2026-05-19T12:00:00Z"
    }
  }
}
```

- [ ] **Step 2: Create ItemRow view.json**

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ItemRow/view.json
```

Content:
```json
{
  "custom": {},
  "params": {
    "item": {},
    "selectedId": 0
  },
  "propConfig": {
    "params.item":       {"paramDirection": "input"},
    "params.selectedId": {"paramDirection": "input"}
  },
  "props": {
    "defaultSize": {
      "width": 240,
      "height": 36
    }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": {"name": "root"},
    "events": {
      "dom": {
        "onClick": {
          "type": "script",
          "scope": "C",
          "config": {
            "script": "system.perspective.sendMessage('itemRowClicked', {'id': self.view.params.item.get('id')}, scope='page')"
          }
        }
      }
    },
    "propConfig": {
      "props.style.classes": {
        "binding": {
          "type": "expr",
          "config": {
            "expression": "if({view.params.item.id} = {view.params.selectedId}, 'tree-item tree-item-selected', 'tree-item')"
          }
        }
      }
    },
    "props": {
      "direction": "row",
      "alignItems": "center",
      "justify": "space-between",
      "style": {
        "padding": "6px 10px",
        "cursor": "pointer",
        "borderBottom": "1px solid var(--mpp-border-subtle)"
      }
    },
    "children": [
      {
        "type": "ia.container.flex",
        "meta": {"name": "RowText"},
        "position": {"grow": 1, "shrink": 1, "basis": "0"},
        "props": {
          "direction": "column",
          "style": {"overflow": "hidden", "gap": "1px"}
        },
        "children": [
          {
            "type": "ia.display.label",
            "meta": {"name": "LabelPartNumber"},
            "position": {"basis": "auto"},
            "propConfig": {
              "props.text": {
                "binding": {
                  "type": "property",
                  "config": {"path": "view.params.item.partNumber"}
                }
              },
              "props.style.classes": {
                "binding": {
                  "type": "expr",
                  "config": {
                    "expression": "if({view.params.item.isDraft} = true, 'row-pn row-pn-draft', 'row-pn')"
                  }
                }
              }
            },
            "props": {
              "style": {
                "fontSize": "12px",
                "fontWeight": "600"
              }
            }
          },
          {
            "type": "ia.display.label",
            "meta": {"name": "LabelDescription"},
            "position": {"basis": "auto"},
            "propConfig": {
              "props.text": {
                "binding": {
                  "type": "property",
                  "config": {"path": "view.params.item.description"}
                }
              }
            },
            "props": {
              "style": {
                "fontSize": "11px",
                "color": "var(--mpp-text-muted)",
                "whiteSpace": "nowrap",
                "overflow": "hidden",
                "textOverflow": "ellipsis"
              }
            }
          }
        ]
      },
      {
        "type": "ia.display.label",
        "meta": {"name": "BadgeType"},
        "position": {"basis": "auto"},
        "propConfig": {
          "props.text": {
            "binding": {
              "type": "property",
              "config": {"path": "view.params.item.typeBadge"}
            }
          },
          "props.style.classes": {
            "binding": {
              "type": "expr",
              "config": {
                "expression": "if({view.params.item.isDraft} = true, 'badge badge-draft', 'badge badge-purple')"
              }
            }
          }
        },
        "props": {
          "style": {
            "fontSize": "10px",
            "padding": "1px 5px"
          }
        }
      }
    ]
  }
}
```

Notes:
- The row fires a **page-scoped** message `itemRowClicked` with the item's id. The parent ItemMaster view's `propConfig` registers a handler for that message (added in Step 4).
- `tree-item` and `tree-item-selected` are stylesheet classes from the existing tree styling (already in `psc-tree-panel` family). They give hover + selected backgrounds.
- `row-pn` / `row-pn-draft` are inline-style hooks for the draft styling (`color: var(--status-draft)` from the mockup). Verify the class exists; if not, fall back to an inline `style.color` expression binding.

- [ ] **Step 3: Verify row-pn classes exist**

Search the stylesheet:
```
Grep pattern="psc-row-pn|psc-tree-item-selected" path="ignition/projects/MPP_Config/com.inductiveautomation.perspective/stylesheet/stylesheet.css"
```

If `psc-tree-item-selected` exists but `psc-row-pn` does not, leave the binding as-is and let the label render in the default text color for both cases (the "draft" visual cue is already provided by `badge-draft` on the badge — the dim text-color cue from the mockup is a nice-to-have, not a Phase 1 requirement).

If both classes are missing, replace the two affected `propConfig.props.style.classes` bindings with inline class strings (`"tree-item"` and `"row-pn"` respectively, removing the conditional) so the row still renders cleanly.

- [ ] **Step 4: Modify ItemMaster view.json — replace placeholder with Main split + LeftPanel**

```
Read ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json
```

Apply this edit to replace the `PlaceholderBody` element (and add the page-scoped message handler at the view level via `propConfig`):

```
old_string:       {
        "type": "ia.display.label",
        "meta": {"name": "PlaceholderBody"},
        "position": {"grow": 1, "basis": "0"},
        "props": {
          "text": "Item Master shell — Phase 1 build in progress.",
          "style": {
            "padding": "32px",
            "color": "var(--mpp-text-muted)",
            "fontStyle": "italic"
          }
        }
      }
    ]
  }
}

new_string:       {
        "type": "ia.container.flex",
        "meta": {"name": "Main"},
        "position": {"grow": 1, "basis": "0"},
        "props": {
          "direction": "row",
          "style": {"overflow": "hidden", "borderTop": "1px solid var(--mpp-border-subtle)"}
        },
        "children": [
          {
            "type": "ia.container.flex",
            "meta": {"name": "LeftPanel"},
            "position": {"basis": "240px", "shrink": 0},
            "props": {
              "direction": "column",
              "style": {
                "background": "var(--mpp-surface-nav)",
                "borderRight": "1px solid var(--mpp-border-subtle)"
              }
            },
            "children": [
              {
                "type": "ia.container.flex",
                "meta": {"name": "FilterBar"},
                "position": {"basis": "auto", "shrink": 0},
                "props": {
                  "direction": "column",
                  "style": {
                    "padding": "8px 10px",
                    "borderBottom": "1px solid var(--mpp-border-subtle)",
                    "gap": "6px"
                  }
                },
                "children": [
                  {
                    "type": "ia.input.text-field",
                    "meta": {"name": "InputSearch"},
                    "position": {"basis": "auto"},
                    "propConfig": {
                      "props.text": {
                        "binding": {
                          "type": "property",
                          "config": {"bidirectional": true, "path": "view.custom.search"}
                        }
                      }
                    },
                    "props": {
                      "placeholder": "🔍 Search items…",
                      "style": {"classes": "search-input"}
                    }
                  },
                  {
                    "type": "ia.input.dropdown",
                    "meta": {"name": "DropdownTypeFilter"},
                    "position": {"basis": "auto"},
                    "propConfig": {
                      "props.value": {
                        "binding": {
                          "type": "property",
                          "config": {"bidirectional": true, "path": "view.custom.typeFilter"}
                        }
                      }
                    },
                    "props": {
                      "options": [
                        {"label": "All Types",      "value": "All Types"},
                        {"label": "Raw Material",   "value": "Raw Material"},
                        {"label": "Component",      "value": "Component"},
                        {"label": "Sub-Assembly",   "value": "Sub-Assembly"},
                        {"label": "Finished Good",  "value": "Finished Good"},
                        {"label": "Pass-Through",   "value": "Pass-Through"}
                      ],
                      "style": {"classes": "select"}
                    }
                  }
                ]
              },
              {
                "type": "ia.display.flex-repeater",
                "meta": {"name": "ItemList"},
                "position": {"grow": 1, "basis": "0"},
                "propConfig": {
                  "props.instances": {
                    "binding": {
                      "type": "expr",
                      "config": {
                        "expression": "forEach({view.custom.items}, {'item': it, 'selectedId': {view.custom.selected.meta.Id}})"
                      }
                    }
                  }
                },
                "props": {
                  "path": "BlueRidge/Components/Parts/ItemMaster/ItemRow",
                  "direction": "column",
                  "elementPosition": {"basis": "auto"},
                  "useDefaultViewWidth": false,
                  "useDefaultViewHeight": false,
                  "style": {"overflowY": "auto", "padding": "4px 0"}
                }
              }
            ]
          },
          {
            "type": "ia.display.label",
            "meta": {"name": "RightPlaceholder"},
            "position": {"grow": 1, "basis": "0"},
            "props": {
              "text": "Detail area — wired in Task 4.",
              "style": {
                "padding": "32px",
                "color": "var(--mpp-text-muted)",
                "fontStyle": "italic"
              }
            }
          }
        ],
        "scripts": {
          "customMethods": [],
          "extensionFunctions": null,
          "messageHandlers": [
            {
              "messageType": "itemRowClicked",
              "pageScope": true,
              "viewScope": false,
              "sessionScope": false,
              "script": "\tclickedId = payload.get('id') if payload else None\n\tif clickedId is None:\n\t\treturn\n\tfor it in self.view.custom.items:\n\t\tif it.get('id') == clickedId:\n\t\t\tif it.get('id') == 1:\n\t\t\t\tself.view.custom.editDraft = dict(self.view.custom.selected)\n\t\t\telse:\n\t\t\t\tbundle = {'meta': dict(it), 'containerConfig': {}, 'routes': {'steps': []}, 'boms': {'lines': []}, 'qualitySpecs': [], 'eligibility': {'rows': []}}\n\t\t\t\tself.view.custom.selected  = bundle\n\t\t\t\tself.view.custom.editDraft = dict(bundle)\n\t\t\tself.view.custom.mode = 'update'\n\t\t\tbreak"
            }
          ]
        }
      }
    ]
  }
}
```

> **Note on the `forEach` expression:** Ignition's expression language uses `forEach(list, expr)` to map each element to a new shape. Each instance dict supplied to the repeater becomes the `view.params.*` of that ItemRow instance. The inner `it` is the iterator variable.
>
> **Note on the page-scoped message handler:** Lives at `root.scripts.messageHandlers[]` (verified against the existing `Audit/FailureLog` view that handles `applyFilterFromTile` with the same pattern). Each handler is an object with `messageType`, `pageScope`, `viewScope`, `sessionScope`, and `script`. The script body is interpreted as a function body — leading tabs `\t` on every line per Ignition convention. `payload` is auto-injected as the message payload. Early `return` is allowed (as in FailureLog's existing handler).
>
> Behavior: when item id 1 (5G0) is clicked, `editDraft` is reset to a fresh copy of the original `selected` bundle (which never changed because Phase 1 has no Save) — effectively a "revert to dummy" for the 5G0 row. When any other item id is clicked, an empty-but-shaped bundle is constructed so the embedded tab bindings don't NPE on missing keys. Phase 2 will replace this with a `BlueRidge.Parts.Item.getOne(id)` call that hydrates the full bundle from the DB.

- [ ] **Step 5: Scan**

```powershell
.\scan.ps1
```
Expected: HTTP 200.

- [ ] **Step 6: Browser verification**

Reload `/items`. Should see:
- Title bar unchanged
- 240 px left panel with Search input + Type filter dropdown + 5 item rows (5G0, 5G0-C, PNA, 6MA-HSG draft, RPY)
- 6MA-HSG row's badge shows "PT" with the draft (amber) color
- Right side shows italic placeholder "Detail area — wired in Task 4."
- Clicking any row updates `view.custom.selected.meta.Id` (visible via the selected-row styling if `tree-item-selected` exists; otherwise no obvious visual change yet)

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ItemRow/
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json
git commit -m "feat(item-master): left panel with item list (ItemRow flex-repeater)"
```

---

## Task 4: DetailsHeader — always-visible item details form

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json` (replace `RightPlaceholder` with DetailArea > DetailsHeader + a new TabContainerPlaceholder)

- [ ] **Step 1: Replace the RightPlaceholder**

```
Read ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json
```

Apply this edit:

```
old_string:           {
            "type": "ia.display.label",
            "meta": {"name": "RightPlaceholder"},
            "position": {"grow": 1, "basis": "0"},
            "props": {
              "text": "Detail area — wired in Task 4.",
              "style": {
                "padding": "32px",
                "color": "var(--mpp-text-muted)",
                "fontStyle": "italic"
              }
            }
          }

new_string:           {
            "type": "ia.container.flex",
            "meta": {"name": "DetailArea"},
            "position": {"grow": 1, "basis": "0"},
            "props": {
              "direction": "column",
              "style": {"overflow": "hidden"}
            },
            "children": [
              {
                "type": "ia.container.flex",
                "meta": {"name": "DetailsHeader"},
                "position": {"basis": "auto", "shrink": 0},
                "props": {
                  "direction": "column",
                  "style": {
                    "padding": "10px 14px",
                    "borderBottom": "1px solid var(--mpp-border-subtle)",
                    "background": "var(--mpp-surface-card)",
                    "gap": "8px"
                  }
                },
                "children": [
                  {
                    "type": "ia.container.flex",
                    "meta": {"name": "SummaryRow"},
                    "position": {"basis": "auto"},
                    "props": {
                      "direction": "row",
                      "alignItems": "center",
                      "style": {"gap": "8px"}
                    },
                    "children": [
                      {
                        "type": "ia.display.label",
                        "meta": {"name": "SummaryText"},
                        "position": {"basis": "auto"},
                        "propConfig": {
                          "props.text": {
                            "binding": {
                              "type": "expr",
                              "config": {
                                "expression": "{view.custom.editDraft.meta.PartNumber} + ' — ' + {view.custom.editDraft.meta.Description}"
                              }
                            }
                          }
                        },
                        "props": {
                          "style": {"fontSize": "13px", "fontWeight": "600"}
                        }
                      },
                      {
                        "type": "ia.display.label",
                        "meta": {"name": "SummaryBadge"},
                        "position": {"basis": "auto"},
                        "propConfig": {
                          "props.text": {
                            "binding": {
                              "type": "property",
                              "config": {"path": "view.custom.editDraft.meta.ItemTypeName"}
                            }
                          }
                        },
                        "props": {
                          "style": {"classes": "badge badge-published"}
                        }
                      },
                      {
                        "type": "ia.container.flex",
                        "meta": {"name": "SummarySpacer"},
                        "position": {"grow": 1},
                        "props": {}
                      },
                      {
                        "type": "ia.input.button",
                        "meta": {"name": "BtnSave"},
                        "position": {"basis": "auto"},
                        "events": {
                          "component": {
                            "onActionPerformed": {
                              "type": "script",
                              "scope": "C",
                              "config": {
                                "script": "BlueRidge.Common.Notify.toast('Not wired yet', 'Item save lands in Phase 3.', 'info', 5)"
                              }
                            }
                          }
                        },
                        "props": {
                          "text": "Save",
                          "style": {"classes": "btn btn-primary btn-sm"}
                        }
                      },
                      {
                        "type": "ia.input.button",
                        "meta": {"name": "BtnDeprecate"},
                        "position": {"basis": "auto"},
                        "events": {
                          "component": {
                            "onActionPerformed": {
                              "type": "script",
                              "scope": "C",
                              "config": {
                                "script": "BlueRidge.Common.Notify.toast('Not wired yet', 'Item deprecate lands in Phase 3.', 'info', 5)"
                              }
                            }
                          }
                        },
                        "props": {
                          "text": "Deprecate",
                          "style": {"classes": "btn btn-danger btn-sm"}
                        }
                      }
                    ]
                  },
                  {
                    "type": "ia.container.flex",
                    "meta": {"name": "FieldRowIdentity"},
                    "position": {"basis": "auto"},
                    "props": {
                      "direction": "row",
                      "style": {"classes": "field-row", "gap": "12px"}
                    },
                    "children": [
                      {
                        "type": "ia.container.flex",
                        "meta": {"name": "FieldPartNumber"},
                        "position": {"basis": "auto"},
                        "props": {
                          "direction": "column",
                          "style": {"classes": "field", "gap": "2px"}
                        },
                        "children": [
                          {
                            "type": "ia.display.label",
                            "meta": {"name": "LabelPartNumber"},
                            "position": {"basis": "auto"},
                            "props": {"text": "Part Number", "style": {"classes": "field-label"}}
                          },
                          {
                            "type": "ia.input.text-field",
                            "meta": {"name": "InputPartNumber"},
                            "position": {"basis": "auto"},
                            "propConfig": {
                              "props.text": {
                                "binding": {
                                  "type": "property",
                                  "config": {"bidirectional": true, "path": "view.custom.editDraft.meta.PartNumber"}
                                }
                              }
                            },
                            "props": {
                              "enabled": false,
                              "style": {"classes": "search-input", "background": "var(--mpp-surface-card)", "color": "var(--mpp-text-muted)"}
                            }
                          }
                        ]
                      },
                      {
                        "type": "ia.container.flex",
                        "meta": {"name": "FieldItemType"},
                        "position": {"basis": "auto"},
                        "props": {
                          "direction": "column",
                          "style": {"classes": "field", "gap": "2px"}
                        },
                        "children": [
                          {
                            "type": "ia.display.label",
                            "meta": {"name": "LabelItemType"},
                            "position": {"basis": "auto"},
                            "props": {"text": "Item Type", "style": {"classes": "field-label"}}
                          },
                          {
                            "type": "ia.input.text-field",
                            "meta": {"name": "InputItemType"},
                            "position": {"basis": "auto"},
                            "propConfig": {
                              "props.text": {
                                "binding": {
                                  "type": "property",
                                  "config": {"bidirectional": true, "path": "view.custom.editDraft.meta.ItemTypeName"}
                                }
                              }
                            },
                            "props": {
                              "enabled": false,
                              "style": {"classes": "search-input", "background": "var(--mpp-surface-card)", "color": "var(--mpp-text-muted)"}
                            }
                          }
                        ]
                      },
                      {
                        "type": "ia.container.flex",
                        "meta": {"name": "FieldUom"},
                        "position": {"basis": "auto"},
                        "props": {
                          "direction": "column",
                          "style": {"classes": "field", "gap": "2px"}
                        },
                        "children": [
                          {
                            "type": "ia.display.label",
                            "meta": {"name": "LabelUom"},
                            "position": {"basis": "auto"},
                            "props": {"text": "UOM", "style": {"classes": "field-label"}}
                          },
                          {
                            "type": "ia.input.dropdown",
                            "meta": {"name": "DropdownUom"},
                            "position": {"basis": "auto"},
                            "propConfig": {
                              "props.value": {
                                "binding": {
                                  "type": "property",
                                  "config": {"bidirectional": true, "path": "view.custom.editDraft.meta.UomCode"}
                                }
                              }
                            },
                            "props": {
                              "options": [
                                {"label": "EA", "value": "EA"},
                                {"label": "LB", "value": "LB"},
                                {"label": "KG", "value": "KG"}
                              ],
                              "style": {"classes": "select"}
                            }
                          }
                        ]
                      }
                    ]
                  },
                  {
                    "type": "ia.container.flex",
                    "meta": {"name": "FieldRowDescription"},
                    "position": {"basis": "auto"},
                    "props": {
                      "direction": "row",
                      "style": {"classes": "field-row", "gap": "12px"}
                    },
                    "children": [
                      {
                        "type": "ia.container.flex",
                        "meta": {"name": "FieldDescription"},
                        "position": {"grow": 2, "basis": "200px"},
                        "props": {
                          "direction": "column",
                          "style": {"classes": "field", "gap": "2px"}
                        },
                        "children": [
                          {
                            "type": "ia.display.label",
                            "meta": {"name": "LabelDescription"},
                            "position": {"basis": "auto"},
                            "props": {"text": "Description", "style": {"classes": "field-label"}}
                          },
                          {
                            "type": "ia.input.text-field",
                            "meta": {"name": "InputDescription"},
                            "position": {"basis": "auto"},
                            "propConfig": {
                              "props.text": {
                                "binding": {
                                  "type": "property",
                                  "config": {"bidirectional": true, "path": "view.custom.editDraft.meta.Description"}
                                }
                              }
                            },
                            "props": {"style": {"classes": "search-input", "width": "100%"}}
                          }
                        ]
                      },
                      {
                        "type": "ia.container.flex",
                        "meta": {"name": "FieldMacola"},
                        "position": {"grow": 1, "basis": "100px"},
                        "props": {
                          "direction": "column",
                          "style": {"classes": "field", "gap": "2px"}
                        },
                        "children": [
                          {
                            "type": "ia.display.label",
                            "meta": {"name": "LabelMacola"},
                            "position": {"basis": "auto"},
                            "props": {"text": "Macola Part #", "style": {"classes": "field-label"}}
                          },
                          {
                            "type": "ia.input.text-field",
                            "meta": {"name": "InputMacola"},
                            "position": {"basis": "auto"},
                            "propConfig": {
                              "props.text": {
                                "binding": {
                                  "type": "property",
                                  "config": {"bidirectional": true, "path": "view.custom.editDraft.meta.MacolaPartNumber"}
                                }
                              }
                            },
                            "props": {"style": {"classes": "search-input", "width": "100%"}}
                          }
                        ]
                      }
                    ]
                  },
                  {
                    "type": "ia.container.flex",
                    "meta": {"name": "FieldRowMeasures"},
                    "position": {"basis": "auto"},
                    "props": {
                      "direction": "row",
                      "style": {"classes": "field-row", "gap": "12px"}
                    },
                    "children": [
                      {
                        "type": "ia.container.flex",
                        "meta": {"name": "FieldUnitWeight"},
                        "position": {"basis": "auto"},
                        "props": {
                          "direction": "column",
                          "style": {"classes": "field", "gap": "2px"}
                        },
                        "children": [
                          {
                            "type": "ia.display.label",
                            "meta": {"name": "LabelUnitWeight"},
                            "position": {"basis": "auto"},
                            "props": {"text": "Unit Weight", "style": {"classes": "field-label"}}
                          },
                          {
                            "type": "ia.input.text-field",
                            "meta": {"name": "InputUnitWeight"},
                            "position": {"basis": "auto"},
                            "propConfig": {
                              "props.text": {
                                "binding": {
                                  "type": "property",
                                  "config": {"bidirectional": true, "path": "view.custom.editDraft.meta.UnitWeight"}
                                }
                              }
                            },
                            "props": {"style": {"classes": "search-input", "width": "80px"}}
                          }
                        ]
                      },
                      {
                        "type": "ia.container.flex",
                        "meta": {"name": "FieldWeightUom"},
                        "position": {"basis": "auto"},
                        "props": {
                          "direction": "column",
                          "style": {"classes": "field", "gap": "2px"}
                        },
                        "children": [
                          {
                            "type": "ia.display.label",
                            "meta": {"name": "LabelWeightUom"},
                            "position": {"basis": "auto"},
                            "props": {"text": "Weight UOM", "style": {"classes": "field-label"}}
                          },
                          {
                            "type": "ia.input.dropdown",
                            "meta": {"name": "DropdownWeightUom"},
                            "position": {"basis": "auto"},
                            "propConfig": {
                              "props.value": {
                                "binding": {
                                  "type": "property",
                                  "config": {"bidirectional": true, "path": "view.custom.editDraft.meta.WeightUomCode"}
                                }
                              }
                            },
                            "props": {
                              "options": [
                                {"label": "EA", "value": "EA"},
                                {"label": "LB", "value": "LB"},
                                {"label": "KG", "value": "KG"}
                              ],
                              "style": {"classes": "select"}
                            }
                          }
                        ]
                      },
                      {
                        "type": "ia.container.flex",
                        "meta": {"name": "FieldDefaultSubLotQty"},
                        "position": {"basis": "auto"},
                        "props": {
                          "direction": "column",
                          "style": {"classes": "field", "gap": "2px"}
                        },
                        "children": [
                          {
                            "type": "ia.display.label",
                            "meta": {"name": "LabelDefaultSubLotQty"},
                            "position": {"basis": "auto"},
                            "props": {"text": "Default Sub-Lot Qty", "style": {"classes": "field-label"}}
                          },
                          {
                            "type": "ia.input.text-field",
                            "meta": {"name": "InputDefaultSubLotQty"},
                            "position": {"basis": "auto"},
                            "propConfig": {
                              "props.text": {
                                "binding": {
                                  "type": "property",
                                  "config": {"bidirectional": true, "path": "view.custom.editDraft.meta.DefaultSubLotQty"}
                                }
                              }
                            },
                            "props": {"style": {"classes": "search-input", "width": "80px"}}
                          }
                        ]
                      },
                      {
                        "type": "ia.container.flex",
                        "meta": {"name": "FieldPartsPerBasket"},
                        "position": {"basis": "auto"},
                        "props": {
                          "direction": "column",
                          "style": {"classes": "field", "gap": "2px"}
                        },
                        "children": [
                          {
                            "type": "ia.display.label",
                            "meta": {"name": "LabelPartsPerBasket"},
                            "position": {"basis": "auto"},
                            "props": {"text": "Parts Per Basket", "style": {"classes": "field-label"}}
                          },
                          {
                            "type": "ia.input.text-field",
                            "meta": {"name": "InputPartsPerBasket"},
                            "position": {"basis": "auto"},
                            "propConfig": {
                              "props.text": {
                                "binding": {
                                  "type": "property",
                                  "config": {"bidirectional": true, "path": "view.custom.editDraft.meta.PartsPerBasket"}
                                }
                              }
                            },
                            "props": {"style": {"classes": "search-input", "width": "80px"}}
                          }
                        ]
                      }
                    ]
                  }
                ]
              },
              {
                "type": "ia.display.label",
                "meta": {"name": "TabContainerPlaceholder"},
                "position": {"grow": 1, "basis": "0"},
                "props": {
                  "text": "Tab container — wired in Task 5+.",
                  "style": {
                    "padding": "32px",
                    "color": "var(--mpp-text-muted)",
                    "fontStyle": "italic"
                  }
                }
              }
            ]
          }
```

- [ ] **Step 2: Scan**

```powershell
.\scan.ps1
```
Expected: HTTP 200.

- [ ] **Step 3: Browser verification**

Reload `/items`. Should see:
- DetailsHeader showing "5G0 — 5G0 Front Cover Assembly" + "Finished Good" badge + Save + Deprecate buttons
- 3 form rows: Identity (PartNumber readonly, ItemType readonly, UOM dropdown), Description + Macola, Unit Weight + Weight UOM + Default Sub-Lot + Parts Per Basket
- Editing the Description field flips the title bar "● Unsaved changes" indicator
- Clicking Save fires a toast saying "Not wired yet" with the Phase 3 message
- Clicking Deprecate fires the same kind of toast
- Below: italic "Tab container — wired in Task 5+." placeholder

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json
git commit -m "feat(item-master): details header form bound to editDraft.meta"
```

---

## Task 5: TabStrip with active-state switching

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json` (replace `TabContainerPlaceholder` with TabContainer > TabStrip + new TabPanelsPlaceholder)

- [ ] **Step 1: Replace TabContainerPlaceholder**

Apply this edit:

```
old_string:               {
                "type": "ia.display.label",
                "meta": {"name": "TabContainerPlaceholder"},
                "position": {"grow": 1, "basis": "0"},
                "props": {
                  "text": "Tab container — wired in Task 5+.",
                  "style": {
                    "padding": "32px",
                    "color": "var(--mpp-text-muted)",
                    "fontStyle": "italic"
                  }
                }
              }

new_string:               {
                "type": "ia.container.flex",
                "meta": {"name": "TabContainer"},
                "position": {"grow": 1, "basis": "0"},
                "props": {
                  "direction": "column",
                  "style": {"background": "var(--mpp-surface-card)", "overflow": "hidden"}
                },
                "children": [
                  {
                    "type": "ia.container.flex",
                    "meta": {"name": "TabStrip"},
                    "position": {"basis": "auto", "shrink": 0},
                    "props": {
                      "direction": "row",
                      "style": {"classes": "tab-strip"}
                    },
                    "children": [
                      {
                        "type": "ia.input.button",
                        "meta": {"name": "TabBtnContainerConfig"},
                        "position": {"basis": "auto"},
                        "events": {
                          "component": {
                            "onActionPerformed": {
                              "type": "script",
                              "scope": "C",
                              "config": {"script": "self.view.custom.activeTab = 'containerConfig'"}
                            }
                          }
                        },
                        "propConfig": {
                          "props.style.classes": {
                            "binding": {
                              "type": "expr",
                              "config": {
                                "expression": "if({view.custom.activeTab} = 'containerConfig', 'tab-item tab-item-active', 'tab-item')"
                              }
                            }
                          }
                        },
                        "props": {"text": "Container Config"}
                      },
                      {
                        "type": "ia.input.button",
                        "meta": {"name": "TabBtnRoutes"},
                        "position": {"basis": "auto"},
                        "events": {
                          "component": {
                            "onActionPerformed": {
                              "type": "script",
                              "scope": "C",
                              "config": {"script": "self.view.custom.activeTab = 'routes'"}
                            }
                          }
                        },
                        "propConfig": {
                          "props.style.classes": {
                            "binding": {
                              "type": "expr",
                              "config": {
                                "expression": "if({view.custom.activeTab} = 'routes', 'tab-item tab-item-active', 'tab-item')"
                              }
                            }
                          }
                        },
                        "props": {"text": "Routes"}
                      },
                      {
                        "type": "ia.input.button",
                        "meta": {"name": "TabBtnBoms"},
                        "position": {"basis": "auto"},
                        "events": {
                          "component": {
                            "onActionPerformed": {
                              "type": "script",
                              "scope": "C",
                              "config": {"script": "self.view.custom.activeTab = 'boms'"}
                            }
                          }
                        },
                        "propConfig": {
                          "props.style.classes": {
                            "binding": {
                              "type": "expr",
                              "config": {
                                "expression": "if({view.custom.activeTab} = 'boms', 'tab-item tab-item-active', 'tab-item')"
                              }
                            }
                          }
                        },
                        "props": {"text": "BOMs"}
                      },
                      {
                        "type": "ia.input.button",
                        "meta": {"name": "TabBtnQualitySpecs"},
                        "position": {"basis": "auto"},
                        "events": {
                          "component": {
                            "onActionPerformed": {
                              "type": "script",
                              "scope": "C",
                              "config": {"script": "self.view.custom.activeTab = 'qualitySpecs'"}
                            }
                          }
                        },
                        "propConfig": {
                          "props.style.classes": {
                            "binding": {
                              "type": "expr",
                              "config": {
                                "expression": "if({view.custom.activeTab} = 'qualitySpecs', 'tab-item tab-item-active', 'tab-item')"
                              }
                            }
                          }
                        },
                        "props": {"text": "Quality Specs"}
                      },
                      {
                        "type": "ia.input.button",
                        "meta": {"name": "TabBtnEligibility"},
                        "position": {"basis": "auto"},
                        "events": {
                          "component": {
                            "onActionPerformed": {
                              "type": "script",
                              "scope": "C",
                              "config": {"script": "self.view.custom.activeTab = 'eligibility'"}
                            }
                          }
                        },
                        "propConfig": {
                          "props.style.classes": {
                            "binding": {
                              "type": "expr",
                              "config": {
                                "expression": "if({view.custom.activeTab} = 'eligibility', 'tab-item tab-item-active', 'tab-item')"
                              }
                            }
                          }
                        },
                        "props": {"text": "Eligibility"}
                      }
                    ]
                  },
                  {
                    "type": "ia.container.flex",
                    "meta": {"name": "TabPanels"},
                    "position": {"grow": 1, "basis": "0"},
                    "props": {
                      "direction": "column",
                      "style": {"overflow": "auto", "padding": "10px 14px", "position": "relative"}
                    },
                    "children": [
                      {
                        "type": "ia.display.label",
                        "meta": {"name": "TabPanelsPlaceholder"},
                        "position": {"basis": "auto"},
                        "propConfig": {
                          "props.text": {
                            "binding": {
                              "type": "expr",
                              "config": {
                                "expression": "'Active tab: ' + {view.custom.activeTab} + ' — embedded views wired in Tasks 6–10.'"
                              }
                            }
                          }
                        },
                        "props": {
                          "style": {
                            "color": "var(--mpp-text-muted)",
                            "fontStyle": "italic"
                          }
                        }
                      }
                    ]
                  }
                ]
              }
```

- [ ] **Step 2: Scan**

```powershell
.\scan.ps1
```

- [ ] **Step 3: Browser verification**

Reload `/items`. Should see:
- Tab strip with 5 buttons (Container Config / Routes / BOMs / Quality Specs / Eligibility), Container Config active
- Below the strip: "Active tab: containerConfig — embedded views wired in Tasks 6–10."
- Click each tab; placeholder text updates to show the new active tab key

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json
git commit -m "feat(item-master): tab strip with active-state switching"
```

---

## Task 6: ContainerConfig embedded view + first tab embed

This task creates the ContainerConfig tab view, embeds it as the first tab panel (replacing the placeholder), and validates the end-to-end bidirectional binding from a child form field back to the parent's `editDraft.containerConfig.<field>` and through to the parent's dirty indicator.

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/resource.json`
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/view.json`
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json` (replace `TabPanelsPlaceholder` with 5 embedded view instances)

- [ ] **Step 1: Create ContainerConfig resource.json**

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/resource.json
```

Content:
```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": ["view.json"],
  "attributes": {
    "lastModification": {
      "actor": "Jacques Potgieter",
      "timestamp": "2026-05-19T12:00:00Z"
    }
  }
}
```

- [ ] **Step 2: Create ContainerConfig view.json**

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/view.json
```

Content:
```json
{
  "custom": {},
  "params": {
    "value": {}
  },
  "propConfig": {
    "params.value": {"paramDirection": "input"}
  },
  "props": {
    "defaultSize": {
      "width": 800,
      "height": 200
    }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": {"name": "root"},
    "props": {
      "direction": "column",
      "style": {"classes": "detail-panel", "padding": "12px 14px", "gap": "10px"}
    },
    "children": [
      {
        "type": "ia.display.label",
        "meta": {"name": "PanelHeader"},
        "position": {"basis": "auto"},
        "props": {
          "text": "Container Configuration",
          "style": {"fontSize": "13px", "fontWeight": "600", "marginBottom": "4px"}
        }
      },
      {
        "type": "ia.container.flex",
        "meta": {"name": "FieldRow1"},
        "position": {"basis": "auto"},
        "props": {"direction": "row", "style": {"classes": "field-row", "gap": "12px"}},
        "children": [
          {
            "type": "ia.container.flex",
            "meta": {"name": "FieldTraysPerContainer"},
            "position": {"basis": "auto"},
            "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
            "children": [
              {
                "type": "ia.display.label",
                "meta": {"name": "LabelTraysPerContainer"},
                "position": {"basis": "auto"},
                "props": {"text": "Trays Per Container", "style": {"classes": "field-label"}}
              },
              {
                "type": "ia.input.text-field",
                "meta": {"name": "InputTraysPerContainer"},
                "position": {"basis": "auto"},
                "propConfig": {
                  "props.text": {
                    "binding": {
                      "type": "property",
                      "config": {"bidirectional": true, "path": "view.params.value.TraysPerContainer"}
                    }
                  }
                },
                "props": {"style": {"classes": "search-input", "width": "80px"}}
              }
            ]
          },
          {
            "type": "ia.container.flex",
            "meta": {"name": "FieldPartsPerTray"},
            "position": {"basis": "auto"},
            "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
            "children": [
              {
                "type": "ia.display.label",
                "meta": {"name": "LabelPartsPerTray"},
                "position": {"basis": "auto"},
                "props": {"text": "Parts Per Tray", "style": {"classes": "field-label"}}
              },
              {
                "type": "ia.input.text-field",
                "meta": {"name": "InputPartsPerTray"},
                "position": {"basis": "auto"},
                "propConfig": {
                  "props.text": {
                    "binding": {
                      "type": "property",
                      "config": {"bidirectional": true, "path": "view.params.value.PartsPerTray"}
                    }
                  }
                },
                "props": {"style": {"classes": "search-input", "width": "80px"}}
              }
            ]
          },
          {
            "type": "ia.container.flex",
            "meta": {"name": "FieldIsSerialized"},
            "position": {"basis": "auto"},
            "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
            "children": [
              {
                "type": "ia.display.label",
                "meta": {"name": "LabelIsSerialized"},
                "position": {"basis": "auto"},
                "props": {"text": "Serialized", "style": {"classes": "field-label"}}
              },
              {
                "type": "ia.input.dropdown",
                "meta": {"name": "DropdownIsSerialized"},
                "position": {"basis": "auto"},
                "propConfig": {
                  "props.value": {
                    "binding": {
                      "type": "property",
                      "config": {"bidirectional": true, "path": "view.params.value.IsSerialized"}
                    }
                  }
                },
                "props": {
                  "options": [
                    {"label": "Yes", "value": true},
                    {"label": "No",  "value": false}
                  ],
                  "style": {"classes": "select"}
                }
              }
            ]
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": {"name": "FieldRow2"},
        "position": {"basis": "auto"},
        "props": {"direction": "row", "style": {"classes": "field-row", "gap": "12px"}},
        "children": [
          {
            "type": "ia.container.flex",
            "meta": {"name": "FieldClosureMethod"},
            "position": {"basis": "auto"},
            "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
            "children": [
              {
                "type": "ia.display.label",
                "meta": {"name": "LabelClosureMethod"},
                "position": {"basis": "auto"},
                "props": {"text": "Closure Method", "style": {"classes": "field-label"}}
              },
              {
                "type": "ia.input.dropdown",
                "meta": {"name": "DropdownClosureMethod"},
                "position": {"basis": "auto"},
                "propConfig": {
                  "props.value": {
                    "binding": {
                      "type": "property",
                      "config": {"bidirectional": true, "path": "view.params.value.ClosureMethod"}
                    }
                  }
                },
                "props": {
                  "options": [
                    {"label": "ByCount",  "value": "ByCount"},
                    {"label": "ByWeight", "value": "ByWeight"},
                    {"label": "ByVision", "value": "ByVision"}
                  ],
                  "style": {"classes": "select"}
                }
              }
            ]
          },
          {
            "type": "ia.container.flex",
            "meta": {"name": "FieldDunnageCode"},
            "position": {"basis": "auto"},
            "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
            "children": [
              {
                "type": "ia.display.label",
                "meta": {"name": "LabelDunnageCode"},
                "position": {"basis": "auto"},
                "props": {"text": "Dunnage Code", "style": {"classes": "field-label"}}
              },
              {
                "type": "ia.input.text-field",
                "meta": {"name": "InputDunnageCode"},
                "position": {"basis": "auto"},
                "propConfig": {
                  "props.text": {
                    "binding": {
                      "type": "property",
                      "config": {"bidirectional": true, "path": "view.params.value.DunnageCode"}
                    }
                  }
                },
                "props": {"style": {"classes": "search-input", "width": "120px"}}
              }
            ]
          },
          {
            "type": "ia.container.flex",
            "meta": {"name": "FieldCustomerCode"},
            "position": {"basis": "auto"},
            "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
            "children": [
              {
                "type": "ia.display.label",
                "meta": {"name": "LabelCustomerCode"},
                "position": {"basis": "auto"},
                "props": {"text": "Customer Code", "style": {"classes": "field-label"}}
              },
              {
                "type": "ia.input.text-field",
                "meta": {"name": "InputCustomerCode"},
                "position": {"basis": "auto"},
                "propConfig": {
                  "props.text": {
                    "binding": {
                      "type": "property",
                      "config": {"bidirectional": true, "path": "view.params.value.CustomerCode"}
                    }
                  }
                },
                "props": {"style": {"classes": "search-input", "width": "140px"}}
              }
            ]
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3: Replace `TabPanelsPlaceholder` in ItemMaster with 5 Embedded Views**

```
Read ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json
```

Apply this edit (replaces only the placeholder; the 5 embedded view children will all be added even though only ContainerConfig has a real view yet — Tasks 7–10 fill the rest. The Routes/Boms/QualitySpecs/Eligibility embeds will render a "view not found" message until those views land, which is fine for incremental verification):

```
old_string:                       {
                        "type": "ia.display.label",
                        "meta": {"name": "TabPanelsPlaceholder"},
                        "position": {"basis": "auto"},
                        "propConfig": {
                          "props.text": {
                            "binding": {
                              "type": "expr",
                              "config": {
                                "expression": "'Active tab: ' + {view.custom.activeTab} + ' — embedded views wired in Tasks 6–10.'"
                              }
                            }
                          }
                        },
                        "props": {
                          "style": {
                            "color": "var(--mpp-text-muted)",
                            "fontStyle": "italic"
                          }
                        }
                      }

new_string:                       {
                        "type": "ia.display.view",
                        "meta": {"name": "EmbedContainerConfig"},
                        "position": {"basis": "auto", "grow": 0, "shrink": 0},
                        "propConfig": {
                          "props.params.value": {
                            "binding": {
                              "type": "property",
                              "config": {"bidirectional": true, "path": "view.custom.editDraft.containerConfig"}
                            }
                          },
                          "position.display": {
                            "binding": {
                              "type": "expr",
                              "config": {"expression": "{view.custom.activeTab} = 'containerConfig'"}
                            }
                          }
                        },
                        "props": {
                          "path": "BlueRidge/Components/Parts/ItemMaster/ContainerConfig"
                        }
                      },
                      {
                        "type": "ia.display.view",
                        "meta": {"name": "EmbedRoutes"},
                        "position": {"basis": "auto", "grow": 0, "shrink": 0},
                        "propConfig": {
                          "props.params.value": {
                            "binding": {
                              "type": "property",
                              "config": {"bidirectional": true, "path": "view.custom.editDraft.routes"}
                            }
                          },
                          "position.display": {
                            "binding": {
                              "type": "expr",
                              "config": {"expression": "{view.custom.activeTab} = 'routes'"}
                            }
                          }
                        },
                        "props": {
                          "path": "BlueRidge/Components/Parts/ItemMaster/Routes"
                        }
                      },
                      {
                        "type": "ia.display.view",
                        "meta": {"name": "EmbedBoms"},
                        "position": {"basis": "auto", "grow": 0, "shrink": 0},
                        "propConfig": {
                          "props.params.value": {
                            "binding": {
                              "type": "property",
                              "config": {"bidirectional": true, "path": "view.custom.editDraft.boms"}
                            }
                          },
                          "position.display": {
                            "binding": {
                              "type": "expr",
                              "config": {"expression": "{view.custom.activeTab} = 'boms'"}
                            }
                          }
                        },
                        "props": {
                          "path": "BlueRidge/Components/Parts/ItemMaster/Boms"
                        }
                      },
                      {
                        "type": "ia.display.view",
                        "meta": {"name": "EmbedQualitySpecs"},
                        "position": {"basis": "auto", "grow": 0, "shrink": 0},
                        "propConfig": {
                          "props.params.value": {
                            "binding": {
                              "type": "property",
                              "config": {"bidirectional": true, "path": "view.custom.editDraft.qualitySpecs"}
                            }
                          },
                          "position.display": {
                            "binding": {
                              "type": "expr",
                              "config": {"expression": "{view.custom.activeTab} = 'qualitySpecs'"}
                            }
                          }
                        },
                        "props": {
                          "path": "BlueRidge/Components/Parts/ItemMaster/QualitySpecs"
                        }
                      },
                      {
                        "type": "ia.display.view",
                        "meta": {"name": "EmbedEligibility"},
                        "position": {"basis": "auto", "grow": 0, "shrink": 0},
                        "propConfig": {
                          "props.params.value": {
                            "binding": {
                              "type": "property",
                              "config": {"bidirectional": true, "path": "view.custom.editDraft.eligibility"}
                            }
                          },
                          "position.display": {
                            "binding": {
                              "type": "expr",
                              "config": {"expression": "{view.custom.activeTab} = 'eligibility'"}
                            }
                          }
                        },
                        "props": {
                          "path": "BlueRidge/Components/Parts/ItemMaster/Eligibility"
                        }
                      }
```

- [ ] **Step 4: Scan**

```powershell
.\scan.ps1
```

- [ ] **Step 5: Browser verification — validate the bidirectional binding round-trip**

Reload `/items`. With Container Config tab active:
- Should see the ContainerConfig form (Trays Per Container = 4, Parts Per Tray = 12, Serialized = Yes, ClosureMethod = ByCount, DunnageCode = RD-5G0F, CustomerCode = HONDA-5G0)
- **Critical test:** Edit any field (e.g., change PartsPerTray from 12 to 13). The title bar's `● Unsaved changes` indicator MUST appear. This confirms the bidirectional binding propagates from the embedded child up to the parent's `editDraft.containerConfig.PartsPerTray`, which then differs from `selected.containerConfig.PartsPerTray`.
- Switch to Routes/BOMs/Quality Specs/Eligibility tabs — they'll show "view not found" or similar errors since those views don't exist yet. Switch back to Container Config — form should still show the modified value (state survives tab switch since all 5 embeds are always-mounted).

- [ ] **Step 6: If dirty indicator does NOT flip on field edit**

The bidi-on-object-param mechanism didn't propagate up. Fallback (R1 in spec):

1. Change ContainerConfig's `params.value` param direction from `"input"` to `"output"`, AND
2. Add an `onChange` handler in the parent ItemMaster on `props.params.value` of the EmbedContainerConfig component that writes the received child value back to `view.custom.editDraft.containerConfig`.

If that also fails, switch to a message-based pattern: child fires `containerConfigFieldChanged` page message on each onBlur; parent handler updates `editDraft.containerConfig`. Document the actual working mechanism in a NEW memory entry `feedback_ignition_embedded_view_object_param_bidi.md` so the same investigation isn't repeated for Tasks 7–10.

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json
git commit -m "feat(item-master): ContainerConfig tab embedded with bidi params"
```

---

## Task 7: Routes embedded view (published-only, read-only)

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Routes/resource.json`
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Routes/view.json`

- [ ] **Step 1: Create Routes resource.json**

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Routes/resource.json
```

Content:
```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": ["view.json"],
  "attributes": {
    "lastModification": {
      "actor": "Jacques Potgieter",
      "timestamp": "2026-05-19T12:00:00Z"
    }
  }
}
```

- [ ] **Step 2: Create Routes view.json**

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Routes/view.json
```

Content:
```json
{
  "custom": {},
  "params": {
    "value": {}
  },
  "propConfig": {
    "params.value": {"paramDirection": "input"}
  },
  "props": {
    "defaultSize": {
      "width": 800,
      "height": 320
    }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": {"name": "root"},
    "props": {
      "direction": "column",
      "style": {"gap": "10px"}
    },
    "children": [
      {
        "type": "ia.container.flex",
        "meta": {"name": "HeaderRow"},
        "position": {"basis": "auto"},
        "props": {"direction": "row", "alignItems": "center", "style": {"gap": "8px"}},
        "children": [
          {
            "type": "ia.input.dropdown",
            "meta": {"name": "DropdownVersion"},
            "position": {"basis": "auto"},
            "propConfig": {
              "props.options": {
                "binding": {
                  "type": "expr",
                  "config": {
                    "expression": "[{'label': 'v' + toStr({view.params.value.publishedVersion}) + ' — Effective ' + {view.params.value.effectiveFrom} + ' (Published)', 'value': {view.params.value.publishedVersion}}]"
                  }
                }
              }
            },
            "props": {
              "style": {"classes": "select", "minWidth": "320px"}
            }
          },
          {
            "type": "ia.display.label",
            "meta": {"name": "BadgePublished"},
            "position": {"basis": "auto"},
            "props": {"text": "Published", "style": {"classes": "badge badge-published"}}
          },
          {
            "type": "ia.container.flex",
            "meta": {"name": "HeaderSpacer"},
            "position": {"grow": 1},
            "props": {}
          },
          {
            "type": "ia.input.button",
            "meta": {"name": "BtnNewVersion"},
            "position": {"basis": "auto"},
            "events": {
              "component": {
                "onActionPerformed": {
                  "type": "script",
                  "scope": "C",
                  "config": {
                    "script": "BlueRidge.Common.Notify.toast('Not wired yet', 'Routes versioning workflow lands in Phase 5.', 'info', 5)"
                  }
                }
              }
            },
            "props": {"text": "New Version", "style": {"classes": "btn btn-sm"}}
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": {"name": "PublishedPanel"},
        "position": {"basis": "auto"},
        "props": {"direction": "column", "style": {"classes": "detail-panel", "overflow": "hidden"}},
        "children": [
          {
            "type": "ia.display.table",
            "meta": {"name": "RouteStepsTable"},
            "position": {"basis": "auto"},
            "propConfig": {
              "props.data": {
                "binding": {
                  "type": "property",
                  "config": {"path": "view.params.value.steps"}
                }
              }
            },
            "props": {
              "columns": [
                {"field": "seq",           "header": "#",                  "width": 50,  "editable": false},
                {"field": "areaName",      "header": "Area",               "width": 140, "editable": false},
                {"field": "templateLabel", "header": "Operation Template", "editable": false},
                {"field": "isRequired",    "header": "Required",           "width": 80,  "editable": false, "render": "boolean"},
                {"field": "dataFields",    "header": "Data Collection",    "editable": false}
              ],
              "rows": {"height": 32},
              "style": {"classes": "data-table"}
            }
          },
          {
            "type": "ia.display.label",
            "meta": {"name": "ReadOnlyCaption"},
            "position": {"basis": "auto"},
            "props": {
              "text": "Published — read-only. Click New Version to create a draft copy for editing.",
              "style": {
                "padding": "8px 12px",
                "fontSize": "11px",
                "color": "var(--mpp-text-muted)",
                "fontStyle": "italic"
              }
            }
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3: Scan**

```powershell
.\scan.ps1
```

- [ ] **Step 4: Browser verification**

Reload `/items`, click the **Routes** tab. Should see:
- Version dropdown showing "v2 — Effective 2026-01-15 (Published)"
- Published badge
- New Version button on right (fires "Not wired yet" toast for Phase 5)
- Table with 4 route steps (Die Cast, Trim Shop, Machine Shop, Prod Control) with all 5 columns populated
- Caption: "Published — read-only. Click New Version to create a draft copy for editing."

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Routes/
git commit -m "feat(item-master): Routes tab (published-only, read-only)"
```

---

## Task 8: Boms embedded view (published-only, read-only)

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Boms/resource.json`
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Boms/view.json`

- [ ] **Step 1: Create Boms resource.json**

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Boms/resource.json
```

Content:
```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": ["view.json"],
  "attributes": {
    "lastModification": {
      "actor": "Jacques Potgieter",
      "timestamp": "2026-05-19T12:00:00Z"
    }
  }
}
```

- [ ] **Step 2: Create Boms view.json**

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Boms/view.json
```

Content:
```json
{
  "custom": {},
  "params": {
    "value": {}
  },
  "propConfig": {
    "params.value": {"paramDirection": "input"}
  },
  "props": {
    "defaultSize": {
      "width": 800,
      "height": 280
    }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": {"name": "root"},
    "props": {
      "direction": "column",
      "style": {"gap": "10px"}
    },
    "children": [
      {
        "type": "ia.container.flex",
        "meta": {"name": "HeaderRow"},
        "position": {"basis": "auto"},
        "props": {"direction": "row", "alignItems": "center", "style": {"gap": "8px"}},
        "children": [
          {
            "type": "ia.input.dropdown",
            "meta": {"name": "DropdownVersion"},
            "position": {"basis": "auto"},
            "propConfig": {
              "props.options": {
                "binding": {
                  "type": "expr",
                  "config": {
                    "expression": "[{'label': 'v' + toStr({view.params.value.publishedVersion}) + ' — Effective ' + {view.params.value.effectiveFrom} + ' (Published)', 'value': {view.params.value.publishedVersion}}]"
                  }
                }
              }
            },
            "props": {
              "style": {"classes": "select", "minWidth": "320px"}
            }
          },
          {
            "type": "ia.display.label",
            "meta": {"name": "BadgePublished"},
            "position": {"basis": "auto"},
            "props": {"text": "Published", "style": {"classes": "badge badge-published"}}
          },
          {
            "type": "ia.container.flex",
            "meta": {"name": "HeaderSpacer"},
            "position": {"grow": 1},
            "props": {}
          },
          {
            "type": "ia.input.button",
            "meta": {"name": "BtnNewVersion"},
            "position": {"basis": "auto"},
            "events": {
              "component": {
                "onActionPerformed": {
                  "type": "script",
                  "scope": "C",
                  "config": {
                    "script": "BlueRidge.Common.Notify.toast('Not wired yet', 'BOMs versioning workflow lands in Phase 6.', 'info', 5)"
                  }
                }
              }
            },
            "props": {"text": "New Version", "style": {"classes": "btn btn-sm"}}
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": {"name": "PublishedPanel"},
        "position": {"basis": "auto"},
        "props": {"direction": "column", "style": {"classes": "detail-panel", "overflow": "hidden"}},
        "children": [
          {
            "type": "ia.display.table",
            "meta": {"name": "BomLinesTable"},
            "position": {"basis": "auto"},
            "propConfig": {
              "props.data": {
                "binding": {
                  "type": "property",
                  "config": {"path": "view.params.value.lines"}
                }
              }
            },
            "props": {
              "columns": [
                {"field": "seq",           "header": "#",         "width": 50,  "editable": false},
                {"field": "componentName", "header": "Component", "editable": false},
                {"field": "partNumber",    "header": "Part Number", "editable": false},
                {"field": "qtyPer",        "header": "Qty",       "width": 80,  "editable": false},
                {"field": "uom",           "header": "UOM",       "width": 80,  "editable": false}
              ],
              "rows": {"height": 32},
              "style": {"classes": "data-table"}
            }
          },
          {
            "type": "ia.display.label",
            "meta": {"name": "ReadOnlyCaption"},
            "position": {"basis": "auto"},
            "props": {
              "text": "Published — read-only. Click New Version to create a draft copy for editing.",
              "style": {
                "padding": "8px 12px",
                "fontSize": "11px",
                "color": "var(--mpp-text-muted)",
                "fontStyle": "italic"
              }
            }
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3: Scan**

```powershell
.\scan.ps1
```

- [ ] **Step 4: Browser verification**

Reload `/items`, click the **BOMs** tab. Should see:
- Version dropdown showing "v1 — Effective 2026-01-15 (Published)"
- Published badge
- New Version button (fires "Not wired yet" toast for Phase 6)
- Table with 2 rows (Front Cover Casting 5G0-C qty=1 EA, Mounting Pin PNA qty=2 EA)
- Caption: read-only message

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Boms/
git commit -m "feat(item-master): BOMs tab (published-only, read-only)"
```

---

## Task 9: QualitySpecs embedded view (read-only linked specs)

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/QualitySpecs/resource.json`
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/QualitySpecs/view.json`

- [ ] **Step 1: Create QualitySpecs resource.json**

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/QualitySpecs/resource.json
```

Content:
```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": ["view.json"],
  "attributes": {
    "lastModification": {
      "actor": "Jacques Potgieter",
      "timestamp": "2026-05-19T12:00:00Z"
    }
  }
}
```

- [ ] **Step 2: Create QualitySpecs view.json**

The QualitySpecs param shape is a `list[dict]` (not an Object wrapper). The view embeds a table fed directly by `view.params.value`.

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/QualitySpecs/view.json
```

Content:
```json
{
  "custom": {},
  "params": {
    "value": []
  },
  "propConfig": {
    "params.value": {"paramDirection": "input"}
  },
  "props": {
    "defaultSize": {
      "width": 800,
      "height": 240
    }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": {"name": "root"},
    "props": {
      "direction": "column",
      "style": {"gap": "10px"}
    },
    "children": [
      {
        "type": "ia.display.label",
        "meta": {"name": "PanelHeader"},
        "position": {"basis": "auto"},
        "propConfig": {
          "props.text": {
            "binding": {
              "type": "expr",
              "config": {
                "expression": "'Linked Quality Specs for ' + {view.custom.itemDisplay}"
              }
            }
          }
        },
        "props": {
          "style": {"fontSize": "13px", "fontWeight": "600"}
        }
      },
      {
        "type": "ia.container.flex",
        "meta": {"name": "Panel"},
        "position": {"basis": "auto"},
        "props": {"direction": "column", "style": {"classes": "detail-panel", "overflow": "hidden"}},
        "children": [
          {
            "type": "ia.display.table",
            "meta": {"name": "SpecsTable"},
            "position": {"basis": "auto"},
            "propConfig": {
              "props.data": {
                "binding": {
                  "type": "property",
                  "config": {"path": "view.params.value"}
                }
              }
            },
            "props": {
              "columns": [
                {"field": "specName",      "header": "Spec Name"},
                {"field": "activeVersion", "header": "Active Version", "width": 120},
                {"field": "statusLabel",   "header": "Status",         "width": 100}
              ],
              "rows": {"height": 36},
              "style": {"classes": "data-table"}
            }
          }
        ]
      },
      {
        "type": "ia.display.label",
        "meta": {"name": "GoToSpecHint"},
        "position": {"basis": "auto"},
        "props": {
          "text": "Phase 7 will add a 'Go to spec' navigation button per row.",
          "style": {
            "padding": "8px 0",
            "fontSize": "11px",
            "color": "var(--mpp-text-muted)",
            "fontStyle": "italic"
          }
        }
      }
    ]
  }
}
```

Note on `view.custom.itemDisplay`: it's not provided by the parent in Phase 1. The expression will render `'Linked Quality Specs for null'` (or empty depending on how Ignition serializes null in string concatenation). Either:
- Leave the header static: `"text": "Linked Quality Specs"` (drop the expression binding)
- Or pass a second param from the parent in a future task

For Phase 1, the simpler choice is the static header. **Apply this correction inline** before writing — replace the `PanelHeader` element's `propConfig` block with a plain static `props.text`:

```json
{
  "type": "ia.display.label",
  "meta": {"name": "PanelHeader"},
  "position": {"basis": "auto"},
  "props": {
    "text": "Linked Quality Specs",
    "style": {"fontSize": "13px", "fontWeight": "600"}
  }
}
```

(Drop the `propConfig` block entirely on `PanelHeader`.)

- [ ] **Step 3: Scan**

```powershell
.\scan.ps1
```

- [ ] **Step 4: Browser verification**

Reload `/items`, click the **Quality Specs** tab. Should see:
- Static header "Linked Quality Specs"
- Table with 2 rows: 5G0 Dimensional Spec / v2 / Active, 5G0 Visual Inspection / v1 / Active
- Italic note about Phase 7

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/QualitySpecs/
git commit -m "feat(item-master): Quality Specs tab (read-only linked list)"
```

---

## Task 10: Eligibility embedded view (Area dropdown + machine table)

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Eligibility/resource.json`
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Eligibility/view.json`

- [ ] **Step 1: Create Eligibility resource.json**

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Eligibility/resource.json
```

Content:
```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": ["view.json"],
  "attributes": {
    "lastModification": {
      "actor": "Jacques Potgieter",
      "timestamp": "2026-05-19T12:00:00Z"
    }
  }
}
```

- [ ] **Step 2: Create Eligibility view.json**

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Eligibility/view.json
```

Content:
```json
{
  "custom": {},
  "params": {
    "value": {}
  },
  "propConfig": {
    "params.value": {"paramDirection": "input"}
  },
  "props": {
    "defaultSize": {
      "width": 800,
      "height": 280
    }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": {"name": "root"},
    "props": {
      "direction": "column",
      "style": {"gap": "10px"}
    },
    "children": [
      {
        "type": "ia.container.flex",
        "meta": {"name": "FilterRow"},
        "position": {"basis": "auto"},
        "props": {"direction": "row", "alignItems": "center", "style": {"gap": "8px"}},
        "children": [
          {
            "type": "ia.display.label",
            "meta": {"name": "LabelArea"},
            "position": {"basis": "auto"},
            "props": {"text": "Area:", "style": {"fontSize": "12px", "color": "var(--mpp-text-muted)"}}
          },
          {
            "type": "ia.input.dropdown",
            "meta": {"name": "DropdownArea"},
            "position": {"basis": "auto"},
            "propConfig": {
              "props.value": {
                "binding": {
                  "type": "property",
                  "config": {"bidirectional": true, "path": "view.params.value.selectedArea"}
                }
              }
            },
            "props": {
              "options": [
                {"label": "All Areas",    "value": "All Areas"},
                {"label": "Die Cast",     "value": "Die Cast"},
                {"label": "Trim Shop",    "value": "Trim Shop"},
                {"label": "Machine Shop", "value": "Machine Shop"}
              ],
              "style": {"classes": "select"}
            }
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": {"name": "Panel"},
        "position": {"basis": "auto"},
        "props": {"direction": "column", "style": {"classes": "detail-panel", "overflow": "hidden"}},
        "children": [
          {
            "type": "ia.container.flex",
            "meta": {"name": "PanelHeader"},
            "position": {"basis": "auto"},
            "props": {"direction": "row", "style": {"padding": "8px 12px", "borderBottom": "1px solid var(--mpp-border-subtle)"}},
            "children": [
              {
                "type": "ia.display.label",
                "meta": {"name": "PanelHeaderLabel"},
                "position": {"basis": "auto"},
                "propConfig": {
                  "props.text": {
                    "binding": {
                      "type": "expr",
                      "config": {"expression": "'Machine Eligibility — ' + {view.params.value.selectedArea} + ' area'"}
                    }
                  }
                },
                "props": {"style": {"fontSize": "13px", "fontWeight": "600"}}
              }
            ]
          },
          {
            "type": "ia.display.table",
            "meta": {"name": "MachineTable"},
            "position": {"basis": "auto"},
            "propConfig": {
              "props.data": {
                "binding": {
                  "type": "property",
                  "config": {"path": "view.params.value.rows"}
                }
              }
            },
            "props": {
              "columns": [
                {"field": "machineName", "header": "Machine"},
                {"field": "code",        "header": "Code",     "width": 100},
                {"field": "tonnage",     "header": "Tonnage",  "width": 110},
                {"field": "eligible",    "header": "Eligible", "width": 90, "render": "boolean", "editable": true}
              ],
              "rows": {"height": 32},
              "style": {"classes": "data-table"}
            }
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3: Scan**

```powershell
.\scan.ps1
```

- [ ] **Step 4: Browser verification**

Reload `/items`, click the **Eligibility** tab. Should see:
- "Area:" label + dropdown defaulting to "Die Cast"
- Panel with header "Machine Eligibility — Die Cast area" (updates when dropdown changes — validates child writeback to view.params.value.selectedArea then bubbles up via the parent's bidi binding)
- Table with 4 machines (DC-003, DC-007, DC-012 all checked; DC-015 unchecked)
- Toggling the Eligible checkbox flips the title bar dirty indicator (validates eligibility editing also rounds-trips through bidi params)

- [ ] **Step 5: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Eligibility/
git commit -m "feat(item-master): Eligibility tab (Area dropdown + machine table)"
```

---

## Task 11: AddItem popup view + wire +Add Item button

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/AddItem/resource.json`
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/AddItem/view.json`
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json` (wire `BtnAddItem` onClick to open the popup)

- [ ] **Step 1: Create AddItem resource.json**

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/AddItem/resource.json
```

Content:
```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": ["view.json"],
  "attributes": {
    "lastModification": {
      "actor": "Jacques Potgieter",
      "timestamp": "2026-05-19T12:00:00Z"
    }
  }
}
```

- [ ] **Step 2: Create AddItem view.json**

```
Write ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/AddItem/view.json
```

Content:
```json
{
  "custom": {
    "draft": {
      "PartNumber": "",
      "ItemTypeName": "",
      "UomCode": "EA",
      "Description": "",
      "UnitWeight": null,
      "WeightUomCode": "",
      "DefaultSubLotQty": null,
      "PartsPerBasket": null,
      "MacolaPartNumber": ""
    }
  },
  "params": {},
  "props": {
    "defaultSize": {
      "width": 560,
      "height": 560
    }
  },
  "root": {
    "type": "ia.container.flex",
    "meta": {"name": "root"},
    "props": {
      "direction": "column",
      "style": {"classes": "modal", "height": "100%"}
    },
    "children": [
      {
        "type": "ia.container.flex",
        "meta": {"name": "ModalHeader"},
        "position": {"basis": "auto", "shrink": 0},
        "props": {
          "direction": "row",
          "alignItems": "center",
          "justify": "space-between",
          "style": {"classes": "modal-header"}
        },
        "children": [
          {
            "type": "ia.display.label",
            "meta": {"name": "HeaderTitle"},
            "position": {"basis": "auto"},
            "props": {"text": "Add Item"}
          },
          {
            "type": "ia.input.button",
            "meta": {"name": "CloseIcon"},
            "position": {"basis": "auto"},
            "events": {
              "dom": {
                "onClick": {
                  "type": "script",
                  "scope": "C",
                  "config": {"script": "system.perspective.closePopup(id='mpp-add-item')"}
                }
              }
            },
            "props": {
              "text": "✕",
              "style": {
                "background": "transparent",
                "border": "none",
                "color": "var(--mpp-text-muted)",
                "fontSize": "16px",
                "cursor": "pointer"
              }
            }
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": {"name": "ModalBody"},
        "position": {"grow": 1, "basis": "0"},
        "props": {
          "direction": "column",
          "style": {"classes": "modal-body", "overflowY": "auto", "gap": "16px"}
        },
        "children": [
          {
            "type": "ia.container.flex",
            "meta": {"name": "SectionIdentity"},
            "position": {"basis": "auto"},
            "props": {"direction": "column", "style": {"gap": "8px"}},
            "children": [
              {
                "type": "ia.display.label",
                "meta": {"name": "SectionLabelIdentity"},
                "position": {"basis": "auto"},
                "props": {
                  "text": "Identity",
                  "style": {
                    "fontSize": "10px",
                    "fontWeight": "600",
                    "color": "var(--mpp-text-muted)",
                    "textTransform": "uppercase",
                    "letterSpacing": "0.5px"
                  }
                }
              },
              {
                "type": "ia.container.flex",
                "meta": {"name": "IdentityRow"},
                "position": {"basis": "auto"},
                "props": {"direction": "row", "style": {"classes": "field-row", "gap": "10px"}},
                "children": [
                  {
                    "type": "ia.container.flex",
                    "meta": {"name": "FieldPartNumber"},
                    "position": {"grow": 1, "basis": "0"},
                    "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
                    "children": [
                      {
                        "type": "ia.display.label",
                        "meta": {"name": "LabelPartNumber"},
                        "position": {"basis": "auto"},
                        "props": {"text": "Part Number *", "style": {"classes": "field-label"}}
                      },
                      {
                        "type": "ia.input.text-field",
                        "meta": {"name": "InputPartNumber"},
                        "position": {"basis": "auto"},
                        "propConfig": {
                          "props.text": {
                            "binding": {
                              "type": "property",
                              "config": {"bidirectional": true, "path": "view.custom.draft.PartNumber"}
                            }
                          }
                        },
                        "props": {"placeholder": "e.g., 5G0", "style": {"classes": "search-input", "width": "100%"}}
                      }
                    ]
                  },
                  {
                    "type": "ia.container.flex",
                    "meta": {"name": "FieldItemType"},
                    "position": {"grow": 1, "basis": "0"},
                    "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
                    "children": [
                      {
                        "type": "ia.display.label",
                        "meta": {"name": "LabelItemType"},
                        "position": {"basis": "auto"},
                        "props": {"text": "Item Type *", "style": {"classes": "field-label"}}
                      },
                      {
                        "type": "ia.input.dropdown",
                        "meta": {"name": "DropdownItemType"},
                        "position": {"basis": "auto"},
                        "propConfig": {
                          "props.value": {
                            "binding": {
                              "type": "property",
                              "config": {"bidirectional": true, "path": "view.custom.draft.ItemTypeName"}
                            }
                          }
                        },
                        "props": {
                          "options": [
                            {"label": "Select…",       "value": ""},
                            {"label": "Raw Material",  "value": "Raw Material"},
                            {"label": "Component",     "value": "Component"},
                            {"label": "Sub-Assembly",  "value": "Sub-Assembly"},
                            {"label": "Finished Good", "value": "Finished Good"},
                            {"label": "Pass-Through",  "value": "Pass-Through"}
                          ],
                          "style": {"classes": "select"}
                        }
                      }
                    ]
                  },
                  {
                    "type": "ia.container.flex",
                    "meta": {"name": "FieldUom"},
                    "position": {"grow": 1, "basis": "0"},
                    "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
                    "children": [
                      {
                        "type": "ia.display.label",
                        "meta": {"name": "LabelUom"},
                        "position": {"basis": "auto"},
                        "props": {"text": "UOM *", "style": {"classes": "field-label"}}
                      },
                      {
                        "type": "ia.input.dropdown",
                        "meta": {"name": "DropdownUom"},
                        "position": {"basis": "auto"},
                        "propConfig": {
                          "props.value": {
                            "binding": {
                              "type": "property",
                              "config": {"bidirectional": true, "path": "view.custom.draft.UomCode"}
                            }
                          }
                        },
                        "props": {
                          "options": [
                            {"label": "EA",  "value": "EA"},
                            {"label": "LB",  "value": "LB"},
                            {"label": "KG",  "value": "KG"},
                            {"label": "PCS", "value": "PCS"}
                          ],
                          "style": {"classes": "select"}
                        }
                      }
                    ]
                  }
                ]
              },
              {
                "type": "ia.container.flex",
                "meta": {"name": "FieldDescription"},
                "position": {"basis": "auto"},
                "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
                "children": [
                  {
                    "type": "ia.display.label",
                    "meta": {"name": "LabelDescription"},
                    "position": {"basis": "auto"},
                    "props": {"text": "Description *", "style": {"classes": "field-label"}}
                  },
                  {
                    "type": "ia.input.text-field",
                    "meta": {"name": "InputDescription"},
                    "position": {"basis": "auto"},
                    "propConfig": {
                      "props.text": {
                        "binding": {
                          "type": "property",
                          "config": {"bidirectional": true, "path": "view.custom.draft.Description"}
                        }
                      }
                    },
                    "props": {"placeholder": "e.g., 5G0 Front Cover Assembly", "style": {"classes": "search-input", "width": "100%"}}
                  }
                ]
              }
            ]
          },
          {
            "type": "ia.container.flex",
            "meta": {"name": "SectionWeight"},
            "position": {"basis": "auto"},
            "props": {"direction": "column", "style": {"gap": "8px"}},
            "children": [
              {
                "type": "ia.display.label",
                "meta": {"name": "SectionLabelWeight"},
                "position": {"basis": "auto"},
                "props": {
                  "text": "Weight",
                  "style": {
                    "fontSize": "10px",
                    "fontWeight": "600",
                    "color": "var(--mpp-text-muted)",
                    "textTransform": "uppercase",
                    "letterSpacing": "0.5px"
                  }
                }
              },
              {
                "type": "ia.container.flex",
                "meta": {"name": "WeightRow"},
                "position": {"basis": "auto"},
                "props": {"direction": "row", "style": {"classes": "field-row", "gap": "10px"}},
                "children": [
                  {
                    "type": "ia.container.flex",
                    "meta": {"name": "FieldUnitWeight"},
                    "position": {"grow": 1, "basis": "0"},
                    "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
                    "children": [
                      {
                        "type": "ia.display.label",
                        "meta": {"name": "LabelUnitWeight"},
                        "position": {"basis": "auto"},
                        "props": {"text": "Unit Weight", "style": {"classes": "field-label"}}
                      },
                      {
                        "type": "ia.input.text-field",
                        "meta": {"name": "InputUnitWeight"},
                        "position": {"basis": "auto"},
                        "propConfig": {
                          "props.text": {
                            "binding": {
                              "type": "property",
                              "config": {"bidirectional": true, "path": "view.custom.draft.UnitWeight"}
                            }
                          }
                        },
                        "props": {"placeholder": "0.00", "style": {"classes": "search-input", "width": "100%"}}
                      }
                    ]
                  },
                  {
                    "type": "ia.container.flex",
                    "meta": {"name": "FieldWeightUom"},
                    "position": {"grow": 1, "basis": "0"},
                    "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
                    "children": [
                      {
                        "type": "ia.display.label",
                        "meta": {"name": "LabelWeightUom"},
                        "position": {"basis": "auto"},
                        "props": {"text": "Weight UOM", "style": {"classes": "field-label"}}
                      },
                      {
                        "type": "ia.input.dropdown",
                        "meta": {"name": "DropdownWeightUom"},
                        "position": {"basis": "auto"},
                        "propConfig": {
                          "props.value": {
                            "binding": {
                              "type": "property",
                              "config": {"bidirectional": true, "path": "view.custom.draft.WeightUomCode"}
                            }
                          }
                        },
                        "props": {
                          "options": [
                            {"label": "—",   "value": ""},
                            {"label": "LB",  "value": "LB"},
                            {"label": "KG",  "value": "KG"}
                          ],
                          "style": {"classes": "select"}
                        }
                      }
                    ]
                  }
                ]
              }
            ]
          },
          {
            "type": "ia.container.flex",
            "meta": {"name": "SectionLotConfig"},
            "position": {"basis": "auto"},
            "props": {"direction": "column", "style": {"gap": "8px"}},
            "children": [
              {
                "type": "ia.display.label",
                "meta": {"name": "SectionLabelLotConfig"},
                "position": {"basis": "auto"},
                "props": {
                  "text": "LOT Configuration",
                  "style": {
                    "fontSize": "10px",
                    "fontWeight": "600",
                    "color": "var(--mpp-text-muted)",
                    "textTransform": "uppercase",
                    "letterSpacing": "0.5px"
                  }
                }
              },
              {
                "type": "ia.container.flex",
                "meta": {"name": "LotConfigRow"},
                "position": {"basis": "auto"},
                "props": {"direction": "row", "style": {"classes": "field-row", "gap": "10px"}},
                "children": [
                  {
                    "type": "ia.container.flex",
                    "meta": {"name": "FieldDefaultSubLot"},
                    "position": {"grow": 1, "basis": "0"},
                    "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
                    "children": [
                      {
                        "type": "ia.display.label",
                        "meta": {"name": "LabelDefaultSubLot"},
                        "position": {"basis": "auto"},
                        "props": {"text": "Default Sub-LOT Qty", "style": {"classes": "field-label"}}
                      },
                      {
                        "type": "ia.input.text-field",
                        "meta": {"name": "InputDefaultSubLot"},
                        "position": {"basis": "auto"},
                        "propConfig": {
                          "props.text": {
                            "binding": {
                              "type": "property",
                              "config": {"bidirectional": true, "path": "view.custom.draft.DefaultSubLotQty"}
                            }
                          }
                        },
                        "props": {"placeholder": "24", "style": {"classes": "search-input", "width": "100%"}}
                      }
                    ]
                  },
                  {
                    "type": "ia.container.flex",
                    "meta": {"name": "FieldPartsPerBasket"},
                    "position": {"grow": 1, "basis": "0"},
                    "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
                    "children": [
                      {
                        "type": "ia.display.label",
                        "meta": {"name": "LabelPartsPerBasket"},
                        "position": {"basis": "auto"},
                        "props": {"text": "Parts Per Basket", "style": {"classes": "field-label"}}
                      },
                      {
                        "type": "ia.input.text-field",
                        "meta": {"name": "InputPartsPerBasket"},
                        "position": {"basis": "auto"},
                        "propConfig": {
                          "props.text": {
                            "binding": {
                              "type": "property",
                              "config": {"bidirectional": true, "path": "view.custom.draft.PartsPerBasket"}
                            }
                          }
                        },
                        "props": {"placeholder": "100", "style": {"classes": "search-input", "width": "100%"}}
                      }
                    ]
                  }
                ]
              }
            ]
          },
          {
            "type": "ia.container.flex",
            "meta": {"name": "SectionErp"},
            "position": {"basis": "auto"},
            "props": {"direction": "column", "style": {"gap": "8px"}},
            "children": [
              {
                "type": "ia.display.label",
                "meta": {"name": "SectionLabelErp"},
                "position": {"basis": "auto"},
                "props": {
                  "text": "ERP Integration",
                  "style": {
                    "fontSize": "10px",
                    "fontWeight": "600",
                    "color": "var(--mpp-text-muted)",
                    "textTransform": "uppercase",
                    "letterSpacing": "0.5px"
                  }
                }
              },
              {
                "type": "ia.container.flex",
                "meta": {"name": "FieldMacola"},
                "position": {"basis": "auto"},
                "props": {"direction": "column", "style": {"classes": "field", "gap": "2px"}},
                "children": [
                  {
                    "type": "ia.display.label",
                    "meta": {"name": "LabelMacola"},
                    "position": {"basis": "auto"},
                    "props": {"text": "Macola Part #", "style": {"classes": "field-label"}}
                  },
                  {
                    "type": "ia.input.text-field",
                    "meta": {"name": "InputMacola"},
                    "position": {"basis": "auto"},
                    "propConfig": {
                      "props.text": {
                        "binding": {
                          "type": "property",
                          "config": {"bidirectional": true, "path": "view.custom.draft.MacolaPartNumber"}
                        }
                      }
                    },
                    "props": {"placeholder": "Optional — for future Macola integration", "style": {"classes": "search-input", "width": "100%"}}
                  }
                ]
              }
            ]
          }
        ]
      },
      {
        "type": "ia.container.flex",
        "meta": {"name": "ModalFooter"},
        "position": {"basis": "auto", "shrink": 0},
        "props": {
          "direction": "row",
          "justify": "flex-end",
          "alignItems": "center",
          "style": {"classes": "modal-footer", "gap": "8px"}
        },
        "children": [
          {
            "type": "ia.input.button",
            "meta": {"name": "BtnCancel"},
            "position": {"basis": "auto"},
            "events": {
              "component": {
                "onActionPerformed": {
                  "type": "script",
                  "scope": "C",
                  "config": {"script": "system.perspective.closePopup(id='mpp-add-item')"}
                }
              }
            },
            "props": {"text": "Cancel", "style": {"classes": "btn"}}
          },
          {
            "type": "ia.input.button",
            "meta": {"name": "BtnCreate"},
            "position": {"basis": "auto"},
            "events": {
              "component": {
                "onActionPerformed": {
                  "type": "script",
                  "scope": "C",
                  "config": {"script": "BlueRidge.Common.Notify.toast('Not wired yet', 'Item create lands in Phase 3.', 'info', 5)\nsystem.perspective.closePopup(id='mpp-add-item')"}
                }
              }
            },
            "props": {"text": "Create Item", "style": {"classes": "btn btn-primary"}}
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3: Wire ItemMaster's `BtnAddItem` to open the popup**

```
Read ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json
```

Find the `BtnAddItem` component (under TitleBar) and add an `events` block. The current state has no events on the button; the edit adds one:

```
old_string:           {
            "type": "ia.input.button",
            "meta": {"name": "BtnAddItem"},
            "position": {"basis": "auto"},
            "props": {
              "text": "+ Add Item",
              "style": {"classes": "btn btn-primary"}
            }
          }

new_string:           {
            "type": "ia.input.button",
            "meta": {"name": "BtnAddItem"},
            "position": {"basis": "auto"},
            "events": {
              "component": {
                "onActionPerformed": {
                  "type": "popup",
                  "scope": "C",
                  "config": {
                    "type": "open",
                    "id": "mpp-add-item",
                    "viewPath": "BlueRidge/Components/Popups/AddItem",
                    "modal": true,
                    "showCloseIcon": false,
                    "overlayDismiss": false,
                    "viewportBound": true
                  }
                }
              }
            },
            "props": {
              "text": "+ Add Item",
              "style": {"classes": "btn btn-primary"}
            }
          }
```

> Note: `showCloseIcon: false` because the modal has its own internal × button. `overlayDismiss: false` so clicking outside the modal doesn't dismiss (defensive for Phase 3 when there will be unsaved draft work to protect).

- [ ] **Step 4: Scan**

```powershell
.\scan.ps1
```

- [ ] **Step 5: Browser verification**

Reload `/items`. Click **+ Add Item** in the title bar. Should see:
- Modal opens centered, 560 px wide, with "Add Item" header + × close icon
- Four sections (Identity / Weight / LOT Configuration / ERP Integration) each with their labeled inputs
- Editing any field updates `view.custom.draft.*` (you won't see this externally; it's the modal's internal state)
- Click **Cancel** → modal closes; reopening shows the fields **retain** the values entered (popup view instance is reused unless explicitly destroyed). For Phase 1 that's acceptable; Phase 3's Create flow will reset draft on each open.
- Click **Create Item** → toast fires "Not wired yet" with the Phase 3 message + modal closes
- Click **×** → modal closes
- Click the `+ Add Item` button again — modal reopens (verifies repeatability)

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/AddItem/
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/ItemMaster/view.json
git commit -m "feat(item-master): AddItem modal shell wired to +Add Item button"
```

---

## Task 12: Final smoke pass + plan exit

This is a verification-only task with no new code. It walks the Phase 1 "Done" checklist from the spec end-to-end and captures any deviations in PROJECT_STATUS.md for the next session.

- [ ] **Step 1: Final scan**

```powershell
.\scan.ps1
```
Expected: HTTP 200, no Designer-side errors logged in the Gateway.

- [ ] **Step 2: Walk the Phase 1 "Done" checklist from the spec**

Open the Configuration Tool and verify each of the 9 points in §12 of `docs/superpowers/specs/2026-05-19-item-master-view-shell-design.md`:

1. `scan.ps1` returns green
2. Designer opens the project clean (no NPEs, no missing-resource warnings) — open Designer manually and confirm
3. `/items` page loads and renders identically to mockup §"SCREEN: Item Master" with 5G0 Front Cover selected
4. Clicking any item in the left panel updates the right detail area's PartNumber / Description / ItemType / etc. (for item id 1 = 5G0 the full bundle hydrates; for other ids the meta hydrates and tabs show empty content)
5. Editing any form field flips the `● Unsaved changes` indicator in the title bar — including fields inside embedded tab views (validates bidi binding through embed boundary)
6. Tab switching shows the correct panel (Container Config / Routes / BOMs / Quality Specs / Eligibility)
7. `+Add Item` button opens the AddItem modal; Cancel and Create both close it without DB churn
8. Save / Deprecate / Create Item / New Version buttons fire "Not wired yet" toasts via `BlueRidge.Common.Notify.toast`
9. Sidebar shows the Parts → Item Master link (already present) and clicking it lands on `/items`

- [ ] **Step 3: Capture deviations**

Any check above that fails or deviates needs to land in `PROJECT_STATUS.md`'s "🟠 Open at session end" section, with:
- What was deviating
- Likely cause / hypothesis
- Suggested fix for next session

Critically: if **Step 5** above fails (bidi binding through embed boundary doesn't propagate), document the actual working mechanism that was used as the fallback and add a memory entry `feedback_ignition_embedded_view_object_param_bidi.md` describing what works and what doesn't.

- [ ] **Step 4: Update PROJECT_STATUS.md**

Open `PROJECT_STATUS.md`. Replace the **"🟠 Open at session end"** section heading with a new entry summarizing the Item Master Phase 1 landing. Move the prior audit-pages customMethods-addressing entry down to the "Recent Change Narrative" if it's already addressed in this session; otherwise leave it.

In the "Recent Change Narrative" section, add a new dated entry at the top for 2026-05-19 (or whatever date this lands) describing:
- Phase 1 of Item Master complete
- 7 new view files + page-config update
- Wire-pass roadmap (Phases 2–8) deferred per design doc
- Any deviations / follow-ups noted

- [ ] **Step 5: Commit**

```bash
git add PROJECT_STATUS.md
git commit -m "docs(status): Item Master Phase 1 landed + roadmap noted"
```

- [ ] **Step 6: (Optional) Designer pull verification**

If a teammate is going to open the project after this lands: pull, scan, then open Designer. Verify the new views appear in the project browser at `BlueRidge/Views/Parts/ItemMaster` and `BlueRidge/Components/Parts/ItemMaster/<5 tabs>` and `BlueRidge/Components/Popups/AddItem`. Open each new view and confirm it renders without an error overlay.

---

## Risks Recap (from spec §13)

- **R1: Bidi binding on Embedded View `props.params.value` to an Object may not round-trip.** Validation step is Task 6 Step 5. Fallback documented in Task 6 Step 6. Same fallback pattern applies to Tasks 7–10.
- **R2: Mockup's `Max LOT Size` label vs data model's `PartsPerBasket` repurposing.** Resolved by using `Parts Per Basket` label everywhere in the implementation (per the data model rev). Confirmed across DetailsHeader + AddItem modal.
- **R3: 5-always-mounted-embed perf cost.** Acceptable; revisit if Phase 5/6 surface issues with larger Routes/BOMs tables.
- **R4: Embedded View sizing inside flex parents.** Each Embedded View uses `position: {grow: 0, shrink: 0, basis: "auto"}` and its child view's root has `defaultSize` set. The TabPanels parent has `overflow: auto` + `padding: 10px 14px`. If a child clips, adjust the child's root container `style.flex` or set explicit dimensions.

---

## What's NOT in this plan

Per spec §2 (Non-Goals) — explicitly deferred to later phases:

- Any SQL (Phase 2+)
- Any NQs (Phase 2+)
- Any entity scripts (Phase 2+)
- Real read paths or save flows
- Routes/BOMs Draft mode toggle, +Add Step / +Add Component, Move arrows on draft rows, Publish action, Discard Draft, Effective Date picker
- Per-tab dirty/save extraction (Container Config still saves as part of the page-level Save in Phase 4)
- Audit.ConfigLog writes
- Eligibility hierarchy-cascade awareness (Phase 8)
- Quality Specs cross-navigation (Phase 7)
- ConfirmUnsaved popup wiring for navigation away from /items (lands when there's actually unsaved DB state to protect — Phase 3+)

These are all called out in the spec for traceability.

---

## Self-Review Notes (run prior to plan handoff)

**Spec coverage:**
- ✅ Page route /items → Task 1
- ✅ Sidebar nav → already in place (verified during plan write)
- ✅ ItemMaster page shell + view.custom dummy data → Task 2
- ✅ ItemRow sub-view + LeftPanel → Task 3
- ✅ DetailsHeader form bound to editDraft.meta → Task 4
- ✅ TabStrip → Task 5
- ✅ 5 embedded tab views → Tasks 6–10
- ✅ AddItem popup + button wire → Task 11
- ✅ Final smoke → Task 12
- ✅ Spec Done-checklist coverage → Task 12 Step 2 walks all 9 items
- ✅ R1 bidi fallback path → Task 6 Step 6

**Placeholder scan:** No "TBD"/"TODO" placeholders in steps. The few italic placeholder labels in views (e.g., "Tab container — wired in Task 5+.") are intentional and replaced by subsequent tasks.

**Type consistency:**
- `view.custom.editDraft.containerConfig.<field>` references match `TraysPerContainer`, `PartsPerTray`, `IsSerialized`, `ClosureMethod`, `DunnageCode`, `CustomerCode` consistently across Task 2 (dummy data) and Task 6 (binding paths). `TargetWeight` is in the data shape but not surfaced — that's deliberate (Phase 4 surfaces it conditionally per the spec).
- `view.custom.editDraft.routes.steps[].seq/areaName/templateLabel/isRequired/dataFields` referenced consistently in Task 2 + Task 7.
- `view.custom.editDraft.boms.lines[].seq/componentName/partNumber/qtyPer/uom` referenced consistently in Task 2 + Task 8.
- `view.custom.editDraft.qualitySpecs[].specName/activeVersion/statusLabel` referenced consistently in Task 2 + Task 9.
- `view.custom.editDraft.eligibility.selectedArea/rows[].machineName/code/tonnage/eligible` referenced consistently in Task 2 + Task 10.
- `view.custom.items[].id/partNumber/description/itemTypeName/typeBadge/isDraft` referenced consistently in Task 2 + Task 3.
- AddItem `view.custom.draft.<field>` field names match the snake-case (actually UpperCamelCase) used in DetailsHeader to make the Phase 3 wire pass trivially consistent.
