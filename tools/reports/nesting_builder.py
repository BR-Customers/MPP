"""Nested-child-query support for Ignition report data sources.

The global ignition-reporting skill's ReportBuilder.add_query emits FLAT root
queries only. A nested child runs once per PARENT ROW, with its `?` bound to a
parent row COLUMN rather than to a report parameter -- which is what lets the Lot
Detail report show each ancestor LOT's own process history.

Subclassed here rather than patched into the skill: the skill lives outside this
repo and is shared with other projects. If this proves out, upstream it.

Emitted shape (verified against a Designer-authored donor on 8.3.5 and against two
production 8.1 customer reports):

    QueryReportDataObject
      setRootQuery -> SubQuery
                        setChildren    arraylist[ SubQuery, ... ]   <- may be empty
                        setDataKey     str
                        setQueryConfig PrepStmtQueryConfig

Setter order matters for byte-similarity with Designer output: setChildren,
setDataKey, setQueryConfig.
"""
import os, sys

sys.path.insert(0, os.path.join(os.path.expanduser("~"), ".claude", "skills",
                                "ignition-reporting", "tools"))

from report_builder import (ReportBuilder, C_SUBQ, C_PREP, C_QRDO, C_DSCFG,   # noqa: E402
                            QUERY_TYPE_ID)


class NestingReportBuilder(ReportBuilder):
    """Deliberately overrides two same-named base-class methods: `_subquery` and
    `add_nested_query`. This is NOT an accidental shadow -- both names are
    reused on purpose with an incompatible calling convention. Read this before
    "helpfully" deleting either override or trying to call them the base way.

    Verified against the base ReportBuilder at
    C:\\Users\\JacquesPotgieter\\.claude\\skills\\ignition-reporting\\tools\\report_builder.py
    (both methods present there: `_subquery` at ~line 199, `add_nested_query` at
    ~line 224):

      - Base `add_nested_query(data_key, sql, expr_tokens, children)`: `children`
        is a flat list of `(data_key, sql, expr_tokens)` 3-tuples. Its `_subquery`
        builds those children with NO `children=` argument of their own, so a
        base-built child is always a leaf -- the base API has no way to express
        a grandchild. ONE nesting level only.
      - Ours `add_nested_query(data_key, sql, expr_tokens, children=None)`:
        `children` is a list of recursive {"key", "sql", "tokens", "children"}
        dicts, and `_subquery` recurses into each child's own "children" list.
        Arbitrary nesting depth.

      - Confirmed by reading the base source: base `_subquery`'s `setChildren`
        call is wrapped in `if children:` -- when `children` is falsy (the
        default `None`, i.e. every leaf node), NO `setChildren` call is emitted
        at all for that SubQuery. Our override always calls `setChildren`, even
        with an empty arraylist, because that is what a Designer-authored donor
        emits on leaf SubQuery nodes too (verified against the donor report and
        two production 8.1 customer reports -- see module docstring above).
        Byte-similarity to Designer output was the reason for the override, not
        just the recursion depth.

      - Confirmed by reading the whole base file: no other method in
        report_builder.py calls `_subquery` or `add_nested_query` -- both call
        sites are inside `add_nested_query` itself. So this override shadows
        cleanly today; nothing upstream silently starts calling our version
        with base-shaped arguments.

    The base skill file is shared across projects and lives outside this repo's
    version control; it changed under us mid-task (observed last-write-time
    2026-08-25 14:10). If its `_subquery`/`add_nested_query` shapes change again,
    re-diff this override against the new base before assuming it still shadows
    safely -- this divergence should be reconciled with whoever owns the
    ignition-reporting skill (candidate: upstream the recursive/leaf-setChildren
    behavior into the base class so this subclass override is no longer needed;
    see module docstring "If this proves out, upstream it").
    """

    def _prep(self, sql, expr_tokens):
        return self._obj(C_PREP, [
            self._call("setExpressions",
                       self._arraylist([self._str(t) for t in expr_tokens])),
            self._call("setQuery", self._str(sql)),
            self._call("setSyntaxClassname", self._str(self._syntax)),
        ])

    def _subquery(self, data_key, sql, expr_tokens, children):
        """Build one SubQuery, recursing into children. An empty children list is
           emitted rather than omitted -- that is what Designer writes."""
        kids = [self._subquery(c["key"], c["sql"], c["tokens"], c.get("children") or [])
                for c in (children or [])]
        return self._obj(C_SUBQ, [
            self._call("setChildren", self._arraylist(kids)),
            self._call("setDataKey", self._str(data_key)),
            self._call("setQueryConfig", self._prep(sql, expr_tokens)),
        ])

    def add_nested_query(self, data_key, sql, expr_tokens, children=None):
        """Top-level SQL data source that may carry per-parent-row child queries.

        children: list of {"key", "sql", "tokens", "children"} dicts, recursive.
        A child's tokens name PARENT ROW COLUMNS, e.g. {RelatedLotId}."""
        if not hasattr(self, "_ds_items"):
            self._ds_items = []
        qrdo = self._obj(C_QRDO, [
            self._call("setRootQuery",
                       self._subquery(data_key, sql, expr_tokens, children)),
        ])
        self._ds_items.append(self._obj(C_DSCFG, [
            self._call("setConfigObject", qrdo),
            self._call("setDataSourceId", self._str(QUERY_TYPE_ID)),
        ]))
