"""Summarize paired simulation runs without treating time samples as replicates."""
import csv
import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "output" / "improved_lqr"
METHODS = ["LQI", "RG_AW", "DOB_AW_SAFE", "SAFE_RG_DOB_AW"]
METRICS = ["MaxPitch_deg", "TargetIAE_m_s", "ReferenceRMSE_m", "SettlingTime_s",
           "ElevatorTotalVariation_deg", "PostGustTargetRMSE_m"]


def read_rows(name):
    with (OUT / name).open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def summarize():
    rows = read_rows("monte_carlo_metrics.csv")
    groups = {method: sorted((r for r in rows if r["Method"] == method),
                             key=lambda r: int(r["Seed"])) for method in METHODS}
    seed_lists = [[int(r["Seed"]) for r in groups[m]] for m in METHODS]
    assert seed_lists and all(s == seed_lists[0] for s in seed_lists)
    assert len(set(seed_lists[0])) == len(seed_lists[0])
    rng = np.random.default_rng(20261009)
    n = len(seed_lists[0])
    assert n >= 2
    resamples = rng.integers(0, n, (10000, n))
    summary = {"n": n, "resamples": 10000, "methods": {}, "paired_differences": {}}
    for method, records in groups.items():
        item = {"pitch_exceedance_count": sum(float(r["MaxPitch_deg"]) > 10 for r in records),
                "unsettled_count": sum(not np.isfinite(float(r["SettlingTime_s"])) for r in records),
                "safety_infeasible_count": sum(float(r["SafetyInfeasibleDuration_s"]) > 0 for r in records),
                "governor_infeasible_count": sum(float(r["GovernorInfeasibleUpdates"]) > 0 for r in records)}
        for metric in METRICS:
            values = np.array([float(r[metric]) for r in records])
            assert np.all(np.isfinite(values)), (method, metric)
            item[metric] = {"mean": float(values.mean()), "sd": float(values.std(ddof=1)),
                            "min": float(values.min()), "max": float(values.max()),
                            "mean_ci95": np.quantile(values[resamples].mean(axis=1), [.025, .975]).tolist()}
        summary["methods"][method] = item
    full = groups["SAFE_RG_DOB_AW"]
    for baseline in ["LQI", "DOB_AW_SAFE"]:
        contrast = {}
        for metric in METRICS:
            diff = np.array([float(a[metric]) - float(b[metric])
                             for a, b in zip(full, groups[baseline])])
            contrast[metric] = {"mean": float(diff.mean()),
                                 "mean_ci95": np.quantile(diff[resamples].mean(axis=1), [.025, .975]).tolist()}
        summary["paired_differences"][baseline] = contrast
    (OUT / "analysis_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    lines = ["# 改进纵向控制算法仿真分析", "",
             "统计单位是一组随机气动参数与一条噪声序列，各算法在同组条件下成对运行。",
             f"最终验证样本数为{n}组。置信区间使用10000次成对自助重采样；它反映设定分布下的仿真抽样误差，不能替代真实机型验证。", "",
             "| 方法 | 俯仰峰值 均值±标准差 / ° | 最差俯仰 / ° | 超10°组数 | 目标IAE 均值 / m·s |",
             "|---|---:|---:|---:|---:|"]
    for method in METHODS:
        item = summary["methods"][method]
        pitch = item["MaxPitch_deg"]
        lines.append(f"| {method} | {pitch['mean']:.3f} ± {pitch['sd']:.3f} | {pitch['max']:.3f} | "
                     f"{item['pitch_exceedance_count']}/{n} | {item['TargetIAE_m_s']['mean']:.3f} |")
    lines += ["", "## 解读", "",
              "俯仰包线控制牺牲高度捕获速度，必须同时报告目标IAE及调节时间。各算法使用的内部参考不同，ReferenceRMSE只能解释各自参考跟踪，不能单独作为优劣排名。",
              "参考预测采用标称线性模型，安全滤波会改变实际控制输入。预测不可行计数必须保留，不能声称递归可行或在全部参数空间满足硬约束。",
              "内部6°包线留有4°裕量，采样和突变阵风可能导致略超6°。10°是本项目算法验证阈值，尚无真实机型包线依据。",
              "新增模块均有既有文献基础。贡献为针对原纵向模型推导非匹配扰动稳态补偿、执行器与安全修正一致的抗饱和，以及可复现实验，尚未证明文献首创。", "",
              "## 数值检查", "",
              "原始45秒结果由ode45独立复现；改进模型采用固定步长RK4，并在无噪声标称完整方案上以半步长复算。",
              "负超调已更正为非负峰值超调；仿真内未进入并保持误差带时调节时间记为NaN。末端误差称为有限时刻误差，不作为渐近稳态证明。"]
    (OUT / "analysis.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return summary


if __name__ == "__main__":
    summarize()
