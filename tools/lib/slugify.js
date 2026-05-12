function slugify(text, seen) {
  let slug = String(text)
    .toLowerCase()
    .replace(/<[^>]+>/g, '')                // strip HTML
    .replace(/[^\w\s.-]/g, '')              // drop punctuation except dot/dash/space
    .replace(/\./g, '-')                    // dots to dashes
    .replace(/\s+/g, '-')                   // whitespace to dashes
    .replace(/-+/g, '-')                    // collapse runs
    .replace(/^-|-$/g, '');                 // trim leading/trailing
  if (!slug) slug = 'section';
  if (!seen) return slug;
  if (!seen.has(slug)) { seen.set(slug, 1); return slug; }
  const n = seen.get(slug) + 1;
  seen.set(slug, n);
  return `${slug}-${n}`;
}

module.exports = { slugify };
