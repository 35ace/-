# 飞行器纵向高度与姿态控制

原报告与原基线脚本保留。改进方案沿用原四状态模型及积分LQR增益，新增非匹配扰动补偿、预测参考治理、舵机一致抗饱和与俯仰包线安全滤波。

MATLAB R2025a及Control System Toolbox下，在项目目录运行：

```matlab
simulate_improved_lqr_aircraft_control('output/improved_lqr', 30)
```

该命令执行九种方法、六个工况、四方法的30组配对随机验证和半步长数值检查，输出时间序列、指标、参数与图。参考治理及安全投影不依赖Optimization Toolbox。

安装Python的numpy和python-docx后运行：

```powershell
python analyze_improved_lqr_results.py
python build_improved_report.py
```

报告生成器沿用原稿的文档样式，读取本项目计算结果，生成单独的改进版。数值分析见`output/improved_lqr/analysis.md`，改动和引用依据见`ALGORITHM_CHANGES.md`。

本方案通过降低姿态峰值提高所设测试范围内的约束表现，同时牺牲高度捕获速度。模型尚未对应真实型号，不可将线性仿真或30组随机结果解释为实际飞行器全包线安全保证。
关于飞行器控制算法的报告
