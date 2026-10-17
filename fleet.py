"""Independent provider profiles, migrated from the original single-source store."""

import threading
from pathlib import Path

from .core import Monitor
from .integrations import info as integration_info
from .topup import info as topup_info

CATALOG = [
    ("codex", "Codex", "codex", "套餐额度 · 自动查询"),
    ("trae", "TRAE", "desktop_quota", "积分 · 本机用量页读取 / 手动校正"),
    ("workbuddy", "WorkBuddy", "desktop_quota", "积分 · 本机用量页读取 / 手动校正"),
    ("deepseek", "DeepSeek", "deepseek", "官方账户余额"),
    ("deepseek_harness", "DeepSeek Harness", "app_bridge", "登录账户余额 · Harness 原生桥接 · 充值余额与赠金"),
    ("openai", "GPT / OpenAI API", "openai", "自定预算减组织费用"),
    ("anthropic", "Claude API", "anthropic", "自定预算减组织费用"),
    ("openrouter", "OpenRouter", "openrouter", "多模型共享余额 · Management Key"),
    ("siliconflow", "硅基流动", "siliconflow", "多模型共享余额 · API Key"),
    ("chatgpt", "ChatGPT", "manual_quota", "订阅额度 · 手动记录"),
    ("claude", "Claude / Claude Code", "manual_quota", "订阅额度 · 手动记录"),
    ("gemini", "Gemini", "manual_quota", "额度 · 手动记录"),
    ("kimi", "Kimi 会员 / Code", "manual_quota", "套餐额度 · 手动记录"),
    ("kimi_api_cn", "Kimi API 中国站", "moonshot_cn", "开放平台账户余额 · CNY · 自动查询"),
    ("kimi_api_global", "Kimi API 国际站", "moonshot_global", "开放平台账户余额 · USD · 自动查询"),
    ("qwen", "Qwen 聊天 / 百炼 Token", "manual_quota", "套餐 / 免费 Token · 手动记录"),
    ("qwen_api", "Qwen / 阿里云账户", "aliyun", "阿里云共享可用额度 · 官方 CLI 只读查询"),
    ("doubao", "豆包", "manual_quota", "额度 · 手动记录"),
    ("glm", "智谱 GLM", "manual_quota", "额度 · 手动记录"),
    ("jev", "JEV", "jev", "本机上报用量"),
    ("custom", "自定义服务商", "custom", "HTTPS 余额接口"),
    ("manual", "其他模型", "manual", "手动金额预算"),
]
PROFILES = {row[0]: row for row in CATALOG}


class Fleet:
    def __init__(self, directory, announce=None):
        self.directory = Path(directory)
        self.storage = Monitor(directory)
        self.lock = threading.RLock()
        self.monitors = {}
        self.running = False
        self.announce = announce
        meta = self.storage.read("profiles.json", {})
        if not meta:
            selected = self.storage.config["source"]
            if selected not in PROFILES:
                selected = "deepseek"
            child = self._monitor(selected)
            child.config = dict(self.storage.config)
            child.state = dict(self.storage.state)
            child.write("config.json", child.config)
            child.write("state.json", child.state)
            meta = {"selected": selected, "enabled": [selected]}
            self.storage.write("profiles.json", meta)
        self.selected = meta["selected"]
        self.enabled = set(meta["enabled"])
        for key in self.enabled:
            self._monitor(key)

    def _monitor(self, key):
        if key not in PROFILES:
            raise ValueError("未知模型来源")
        if key not in self.monitors:
            monitor = Monitor(self.directory / "profiles" / key, announce=self.announce)
            if not (monitor.directory / "config.json").exists():
                monitor.config["source"] = PROFILES[key][2]
                monitor.config["model"] = PROFILES[key][1]
                if key in ("trae", "workbuddy"):
                    monitor.config.update(desktop_app=key, quota_unit="积分")
            self.monitors[key] = monitor
        return self.monitors[key]

    def snapshot(self):
        with self.lock:
            state = self._monitor(self.selected).snapshot()
            state["reported_usage"] = self.storage.snapshot()["reported_usage"]
            state["profile"] = self.selected
            state["topup"] = topup_info(self.selected)
            state["profiles"] = []
            for key, name, source, hint in CATALOG:
                snapshot = self._monitor(key).snapshot()
                state["profiles"].append(
                    {
                        "id": key,
                        "name": name,
                        "source": source,
                        "hint": hint,
                        "topup": topup_info(key),
                        "integration": integration_info(key),
                        "enabled": key in self.enabled,
                        "snapshot": snapshot,
                    }
                )
            return state

    def configure(self, values):
        with self.lock:
            key = values.get("profile", values.get("source", self.selected))
            monitor = self._monitor(key)
            values = dict(values, source=PROFILES[key][2])
            if key in ("trae", "workbuddy"):
                values["desktop_app"] = key
            monitor.configure(values)
            self.enabled.add(key)
            self.selected = key
            self.storage.write("profiles.json", {"selected": key, "enabled": sorted(self.enabled)})
            if self.running:
                monitor.start()
        return self.snapshot()

    def select(self, key):
        with self.lock:
            if key not in self.enabled:
                raise ValueError("请先配置此来源")
            self.selected = key
            self.storage.write("profiles.json", {"selected": key, "enabled": sorted(self.enabled)})
        return self.snapshot()

    def refresh(self):
        with self.lock:
            monitor = self._monitor(self.selected)
        monitor.refresh()
        return self.snapshot()

    def record_usage(self, item):
        return self.storage.record_usage(item)

    def start(self):
        with self.lock:
            self.running = True
            for key in self.enabled:
                self._monitor(key).start()

    def close(self):
        with self.lock:
            self.running = False
            monitors = list(self.monitors.values())
        for monitor in monitors:
            monitor.close()
