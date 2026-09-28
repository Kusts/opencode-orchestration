// Bounded-set helper plus untrusted-identifier sanitizer.
// PURE: no imports. Used by identity indexing, mandate plumbing and
// telemetry so all three share one eviction/sanitize semantic.
export function isSafeId(v: unknown): v is string {
  if (typeof v !== "string") return false;
  const t = v.trim();
  if (t.length === 0 || t.length > 64) return false;
  return /^[A-Za-z0-9._:@-]*$/.test(t);
}

// Trimmed safe string, or undefined when the value must be omitted.
export function sanitizeOpt(v: unknown): string | undefined {
  try {
    if (!isSafeId(v)) return undefined;
    return (v as string).trim();
  } catch {
    return undefined;
  }
}

// Make room for one NEW map key: when size is at capacity, drop the
// oldest entry (Map preserves insertion order). Updates to existing keys
// never grow the map. NEVER throws.
export function evictOldestMap<K, V>(map: Map<K, V>, cap: number): void {
  try {
    if (map.size < cap) return;
    const oldest = map.keys().next();
    if (!oldest.done) map.delete(oldest.value);
  } catch {
    // Fail-open: bookkeeping never breaks the session.
  }
}

// Make room for one NEW set member, same oldest-first policy. NEVER throws.
export function evictOldestSet(set: Set<string>, cap: number): void {
  try {
    if (set.size < cap) return;
    const oldest = set.values().next();
    if (!oldest.done) set.delete(oldest.value);
  } catch {
    // Fail-open: bookkeeping never breaks the session.
  }
}

// Bounded insert into a Set: evict oldest when a NEW key arrives at
// capacity. NEVER throws.
export function setAddBounded(set: Set<string>, key: string, cap: number): void {
  try {
    if (!set.has(key) && set.size >= cap) evictOldestSet(set, cap);
    set.add(key);
  } catch {
    // Fail-open: bookkeeping never breaks the session.
  }
}

// Bounded insert into a Map: evict oldest when a NEW key arrives at
// capacity. NEVER throws.
export function mapSetBounded<K, V>(map: Map<K, V>, key: K, value: V, cap: number): void {
  try {
    if (!map.has(key) && map.size >= cap) evictOldestMap(map, cap);
    map.set(key, value);
  } catch {
    // Fail-open: indexing never breaks the session.
  }
}
