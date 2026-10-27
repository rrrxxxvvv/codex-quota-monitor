const {createHash} = require('node:crypto');
function windowsFrom(result) {
  const buckets = result.rateLimitsByLimitId ?? (result.rateLimits ? {[result.rateLimits.limitId || 'codex']: result.rateLimits} : {});
  const windows = {};
  for (const [bucket, limits] of Object.entries(buckets)) {
    for (const slot of ['primary', 'secondary']) {
      const w = limits?.[slot];
      if (!w || !Number.isFinite(w.usedPercent) || !Number.isFinite(w.resetsAt) || !Number.isFinite(w.windowDurationMins)) continue;
      const duration = w.windowDurationMins;
      const durationLabel = duration === 10080 ? '每周' : duration % 60 === 0 ? `${duration / 60} 小时` : `${duration} 分钟`;
      const key = `${bucket}:${duration}:${slot}`;
      windows[key] = {...w, label: `${limits.limitName || bucket} · ${durationLabel}`, remaining: Math.max(0, Math.min(100, 100 - w.usedPercent))};
    }
  }
  return windows;
}

function transition(previous, result, now = Date.now()) {
  const current = windowsFrom(result);
  if (!Object.keys(current).length) throw new Error('服务未返回可用额度窗口；保留上次状态，等待重试。');
  // Missing identity must never allow comparisons across different signed-in accounts.
  if (!result.accountId) throw new Error('服务未返回账号标识，无法安全比较额度。');
  const sameAccount = previous?.accountId === result.accountId;
  const pending = sameAccount ? [...(previous.pending || [])] : [];
  const changes = [];
  const before = sameAccount ? previous.windows || {} : {};
  for (const [key, w] of Object.entries(current)) {
    const old = before[key];
    if (!old) continue;
    const rolled = w.resetsAt > old.resetsAt && now / 1000 >= old.resetsAt;
    const recovered = w.usedPercent < old.usedPercent;
    if (!rolled && !recovered) continue;
    const kind = rolled ? '额度周期已重置' : '可用额度已增加';
    const id = `${key}:${w.resetsAt}:${now}:${w.usedPercent}`;
    const event={id, kind, label: w.label, remaining: w.remaining, previousRemaining: old.remaining, detectedAt: new Date(now).toISOString(), resetsAt: w.resetsAt,windowKey:key,windowDurationMins:w.windowDurationMins};
    pending.push(event);changes.push(event);
  }
  const raw = result.rateLimitResetCredits;
  const resetCredits = raw && Number.isInteger(raw.availableCount) && raw.availableCount >= 0 ? {
    availableCount: raw.availableCount,
    cards: Array.isArray(raw.credits) ? raw.credits.filter(c=>c.status==='available' && c.resetType==='codexRateLimits' && typeof c.id==='string').map(c=>({id:createHash('sha256').update(c.id).digest('hex'),expiresAt:Number.isFinite(c.expiresAt) ? c.expiresAt : null})) : [],
    expiresAt: Array.isArray(raw.credits) ? raw.credits.filter(c=>c.status==='available' && c.resetType==='codexRateLimits').map(c=>Number.isFinite(c.expiresAt) ? c.expiresAt : null) : []
  } : null;
  return {version: 1, accountId: result.accountId, windows: {...before, ...current}, currentWindows: current, resetCredits, pending, changes, checkedAt: new Date(now).toISOString()};
}

module.exports = {windowsFrom, transition};
