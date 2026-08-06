"""BlueRidge.Location.AttributeOptions - dropdown option sets for enumerated
   Location EAV attributes edited in the config app (Plant Hierarchy).

   The generic LocationAttributeValueRow renders a text field for NVARCHAR
   attributes. A few attributes are really a fixed choice list; forAttr(name)
   returns [{label, value}] for those (empty list for everything else, so the
   row keeps its text field). The dropdown is authored allowCustomOptions=true
   so a pre-existing / non-listed value (e.g. a dedicated screen route on an
   older terminal) still renders and is never dropped.

   These are UI reference lists, not domain rules:
     - DefaultScreen options mirror the operator-facing routes curated from the
       MPP project page-config (FAT #13). Parameterized (:areaId/:lotId), dev,
       and non-station routes are intentionally excluded. Keep in sync with
       com.inductiveautomation.perspective/page-config/config.json (MPP project).
     - ConnectionKind is the Printer networked/hardwired choice (FAT #14).

   Change Log:
       2026-08-05 - Initial version (FAT #13 DefaultScreen + #14 ConnectionKind)."""


# Curated operator-station screens a terminal may default to. value = route as
# stored in the DefaultScreen attribute; label pairs the page title with the route.
_DEFAULT_SCREENS = [
    ("/shop-floor/die-cast",              "Die Cast Entry"),
    ("/shop-floor/trim",                  "Trim Station"),
    ("/shop-floor/machining",             "Machining IN / OUT"),
    ("/shop-floor/machining-in",          "Machining IN"),
    ("/shop-floor/machining-out",         "Machining OUT - Split"),
    ("/shop-floor/assembly-in",           "Assembly IN"),
    ("/shop-floor/assembly-serialized",   "Assembly (Serialized)"),
    ("/shop-floor/assembly-nonserialized","Assembly (Non-Serialized)"),
    ("/shop-floor/sort-cage",             "Sort Cage"),
    ("/shop-floor/third-party-inspection","Third-Party Inspection"),
    ("/shop-floor/receiving",             "Receiving"),
    ("/shop-floor/shipping",              "Shipping Dock"),
]

_CONNECTION_KINDS = [
    ("Networked", "Networked (IP:port - validatable)"),
    ("Hardwired", "Hardwired (print-queue name)"),
]


def _shape(pairs):
    return [{"label": "%s  (%s)" % (label, value), "value": value} for (value, label) in pairs]


def forAttr(attributeName):
    """Return [{label, value}] option list for an enumerated attribute name,
       or [] when the attribute is free-text (the row keeps its text field).
       Always returns a list (never None) so a runScript-bound options prop is
       never overwritten with null."""
    name = "%s" % (BlueRidge.Common.Util.extractQualifiedValues(attributeName) or "")
    if name == "DefaultScreen":
        return _shape(_DEFAULT_SCREENS)
    if name == "ConnectionKind":
        # value/label already ordered; _CONNECTION_KINDS is (value, label) too.
        return [{"label": label, "value": value} for (value, label) in _CONNECTION_KINDS]
    return []
