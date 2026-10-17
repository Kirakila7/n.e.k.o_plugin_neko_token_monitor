"""YUI game dialogue and durable low-food reminders, independent of widget visibility."""
import copy
import json
import math
import os
import threading
import time
from pathlib import Path

from .recording import quota_text


def number(value):
    if value is None or value == "" or isinstance(value, bool):
        return None
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (ValueError, TypeError, OverflowError):
        return None


def quota_snapshot(state):
    """Allowlisted facts only. Never put account secrets/endpoints in memory or prompts."""
    cfg = state.get("config", {})
    source = cfg.get("source", "")
    result = {"source": source, "model": str(cfg.get("model") or source)[:100],
              "basis": str(state.get("basis") or "官方账户余额")[:100], "stale": bool(state.get("stale")),
              "remaining": None, "unit": cfg.get("currency", ""), "percent": None,
              "updated_at": state.get("updated_at")}
    if source == "codex":
        windows = [w for w in (state.get("codex_quota") or {}).get("windows", []) if isinstance(w, dict) and number(w.get("remaining")) is not None and 0 <= number(w["remaining"]) <= 100]
        if not windows:
            return None
        window = min(windows, key=lambda w: float(w["remaining"]))
        result.update(remaining=float(window["remaining"]), unit="%", percent=float(window["remaining"]), basis="Codex 套餐额度 · " + str(window.get("label", "限额窗口"))[:60])
    elif source == "desktop_quota" and cfg.get("quota_mode", "auto") == "auto":
        row = state.get("account_quota") or {}
        value, total = number(row.get("remaining")), number(cfg.get("quota_total"))
        if value is None or value < 0:
            return None
        result.update(remaining=value, unit="积分", basis=str(row.get("basis") or "本机用量页读数")[:150])
        if total and total > 0:
            result["percent"] = max(0, min(100, value / total * 100))
            result["basis"] += " · 比例相对自设总积分"
    elif source == "manual_quota" or source == "desktop_quota":
        value = number(cfg.get("quota_remaining"))
        if value is None or value < 0:
            return None
        total = 100 if cfg.get("quota_unit") == "%" else number(cfg.get("quota_total"))
        result.update(remaining=value, unit=cfg.get("quota_unit", "次"), basis="手动记录，不代表实时自动查询", stale=False)
        if total and total > 0:
            result["percent"] = max(0, min(100, value / total * 100))
    elif source == "jev":
        return None  # Local usage is not an account's remaining balance.
    else:
        value = number((state.get("selected") or {}).get("balance"))
        if value is None:
            return None
        result["remaining"] = value
        total = number(cfg.get("budget") if source in ("openai", "anthropic") else cfg.get("balance_total"))
        if total and total > 0:
            result["percent"] = max(0, min(100, value / total * 100))
        if source in ("openai", "anthropic"):
            result["basis"] = "自设预算减已知费用，并非官方账户余额"
        elif source == "manual":
            result["basis"] = "手动填写，不自动扣减，并非官方账户余额"
    return result


def alert_level(state, quota):
    if not quota or quota["stale"] or state.get("error") or not state.get("config", {}).get("alerts", True):
        return 0
    percent, value = quota["percent"], quota["remaining"]
    if value is not None and value <= 0:
        return 3
    if percent is not None and percent <= 10:
        return 2
    if percent is not None and percent <= 25 or value is not None and value <= (number(state.get("config", {}).get("low_balance")) or 0):
        return 1
    return 0


class Companion:
    def __init__(self, directory, monitor, recording, request_reply, announce, clock=time.time):
        self.path = Path(directory) / "yui-care.json"
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.monitor, self.recording = monitor, recording
        self.request_reply, self.announce, self.clock = request_reply, announce, clock
        self.lock = threading.RLock()
        self.stop_event, self.wake = threading.Event(), threading.Event()
        self.worker = None
        self.jobs = {}
        self.last_voice = None
        self.last_result = None
        self.data = {"enabled": True, "voice": True, "interval": 300, "character_name": "YUI", "alerts": {}}
        try:
            raw = json.loads(self.path.read_text())
            if isinstance(raw, dict):
                self.data.update(raw)
        except (OSError, ValueError):
            pass
        self.recording.character_name = self.data["character_name"]

    def save(self):
        temporary = self.path.with_suffix(".tmp")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(self.data, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(self.path)

    def snapshot(self):
        with self.lock:
            return {key: copy.deepcopy(self.data[key]) for key in ("enabled", "voice", "interval", "character_name")} | {"last_delivery": copy.deepcopy(self.last_result), "background": True}

    def configure(self, values):
        with self.lock:
            data = copy.deepcopy(self.data)
            for key in ("enabled", "voice"):
                if key in values:
                    if type(values[key]) is not bool:
                        raise ValueError("提醒开关无效")
                    data[key] = values[key]
            if "interval" in values:
                value = number(values["interval"])
                if value is None or not value.is_integer() or not 60 <= value <= 86400:
                    raise ValueError("提醒间隔应为 60～86400 秒")
                data["interval"] = int(value)
            if "character_name" in values:
                value = values["character_name"]
                if not isinstance(value, str) or not value.strip() or len(value) > 80 or any(ord(c) < 32 or c in "/\\" for c in value):
                    raise ValueError("YUI 角色名无效")
                data["character_name"] = value.strip()
            self.data = data
            self.recording.character_name = data["character_name"]
            if not data["enabled"]:
                self.jobs = {k: v for k, v in self.jobs.items() if k != "alert"}
            self.save()
        self.wake.set()
        return self.snapshot()

    def queue(self, category, line, quota, session_id=None, urgent=False, profile=None, cue=None):
        with self.lock:
            existing = self.jobs.get(category)
            if existing and existing["urgent"] and existing["expires"] > self.clock() and not urgent:
                return
            self.jobs[category] = {"line": line, "quota": quota, "session_id": session_id,
                                   "expires": self.clock() + (30 if category == "alert" or urgent else 20), "urgent": urgent, "profile": profile, "cue": cue}
        self.wake.set()

    def handle_game(self, kind, event_id, session_id=None):
        quota = quota_snapshot(self.monitor.snapshot())
        state = self.recording.action("game", event_id, session_id, kind=kind, quota=quota)
        if not state.get("event_accepted"):
            return state
        if not state.get("active") or session_id and state.get("id") != session_id:
            return state  # Replay saves history, but must never shout from a closed/older session.
        lines = {"reverse": "呜哇！怎么变成本喵被追了！快抱本喵回去喵～",
                 "counter_tag": "呀！被逮住了！不许欺负本喵，救命喵～",
                 "flee": "别、别追本喵啦！本喵只是饿了，快救救本喵喵～",
                 "rescue": "呼……被抱回来就安心多了，谢谢你喵～"}
        if kind in lines:
            self.queue("game", lines[kind], quota, session_id, urgent=kind == "reverse", cue=kind)
        elif kind in ("stop", "pause"):
            with self.lock:
                self.jobs.pop("game", None)
        return state

    def check_alerts(self):
        state = self.monitor.snapshot()
        profiles = [(p["id"], p["snapshot"]) for p in state.get("profiles", []) if p.get("enabled")]
        if not profiles:
            profiles = [(state.get("profile", "current"), state)]
        now = self.clock()
        due = []
        for profile, snapshot in profiles:
            quota = quota_snapshot(snapshot)
            if not quota or quota["stale"] or snapshot.get("error") or not snapshot.get("config", {}).get("alerts", True):
                continue
            level = alert_level(snapshot, quota)
            with self.lock:
                if not self.data["enabled"]:
                    return
                previous = self.data["alerts"].get(profile, {})
                if not level:
                    if previous:
                        self.data["alerts"].pop(profile, None)
                        self.save()
                    continue
                interval = max(60, self.data["interval"] // (2 if level >= 2 else 1))
                last = previous.get("at")
                if last is not None and now >= last and now - last < (60 if level > previous.get("level", 0) else interval):
                    continue
                count = previous.get("count", 0) + 1
                self.data["alerts"][profile] = {"at": now, "level": level, "count": count}
                self.save()
            fact = quota_text(quota)
            lines = [f"那个……{fact}。本喵有点担心，记得补充猫粮喵～",
                     f"本喵又来看猫粮了……{fact}。肚子都快饿扁了，快帮本喵看看喵～",
                     f"呜……{fact}。本喵越来越不安心了，再不添猫粮就要追大肥鱼了喵～"]
            line = lines[min(count - 1, 2)] if level < 3 else f"呜哇！{fact}。猫粮已经见底了，快救救饿肚子的本喵喵～"
            self.recording.remember("low_food", "YUI 因低猫粮尝试第 " + str(count) + " 次提醒；台词：“" + line + "”", quota)
            due.append({"line": line, "quota": quota, "profile": profile})
        if due:
            with self.lock:
                # One voice turn covers every due account, instead of overwriting the first.
                pending = self.jobs.get("alert", {})
                rows = {row["profile"]: row for row in pending.get("alerts", [])} if pending.get("expires", 0) > now else {}
                rows.update({row["profile"]: row for row in due})
                rows = list(rows.values())
                self.queue("alert", "\n".join(row["line"] for row in rows), rows[0]["quota"])
                self.jobs["alert"]["alerts"] = rows

    def deliver(self):
        with self.lock:
            now = self.clock()
            self.jobs = {k: v for k, v in self.jobs.items() if v["expires"] > now}
            if not self.jobs or self.last_voice is not None and now - self.last_voice < 12:
                return
            category = "game" if "game" in self.jobs else "alert"
            job = self.jobs.pop(category)
            if category == "game":
                state = self.recording.snapshot()
                if not state.get("active") or job["session_id"] and state.get("id") != job["session_id"]:
                    return
                latest = quota_snapshot(self.monitor.snapshot())
                if job.get("cue") != "rescue" and (not latest or latest["stale"] or latest["percent"] is None or latest["percent"] >= 10):
                    return
            else:
                latest = self.monitor.snapshot()
                valid = []
                for row in job.get("alerts", [job]):
                    profile = next((p["snapshot"] for p in latest.get("profiles", []) if p.get("id") == row.get("profile") and p.get("enabled")), None) if latest.get("profiles") else latest
                    if profile is not None and alert_level(profile, quota_snapshot(profile)):
                        valid.append(row)
                if not self.data["enabled"] or not valid:
                    return
                job["alerts"] = valid
                job["line"] = "\n".join(row["line"] for row in valid)
            target, voice = self.data["character_name"], self.data["voice"]
            if category == "game" and not voice:
                return
            self.last_voice = now
        submitted = False
        try:
            if voice:
                result = self.request_reply(job["line"], target)
                submitted = bool(result.get("submitted"))
            if not submitted and category == "alert":
                submitted = bool(self.announce(job["line"], target))
        except Exception:
            pass
        with self.lock:
            self.last_result = {"at": now, "kind": category, "submitted": submitted,
                                "playback_confirmed": False, "character_name": target}
        for row in job.get("alerts", [job]):
            self.recording.remember("yui_dialogue", "请求原版 YUI 喊话：“" + row["line"] + "”；" + ("原程序已接受请求，尚未确认实际播放" if submitted else "原程序未接受，不能认定已经出声"), row["quota"])

    def tick(self):
        self.check_alerts()
        self.deliver()

    def start(self):
        if self.worker and self.worker.is_alive():
            return
        def run():
            while not self.stop_event.is_set():
                self.wake.clear()
                try:
                    self.tick()
                except Exception:
                    pass
                self.wake.wait(2)
        self.worker = threading.Thread(target=run, daemon=True, name="catfood-yui-care")
        self.worker.start()

    def close(self):
        self.stop_event.set()
        self.wake.set()
        if self.worker:
            self.worker.join(3)
