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
