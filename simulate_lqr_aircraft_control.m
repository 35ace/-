%% Aircraft control algorithm simulation for topic 5
% Simplified longitudinal aircraft model with integral LQR altitude tracking.
% The script saves figures and a numeric summary for the project report.

clear; clc; close all;

outDir = fullfile(pwd, "output");
if ~exist(outDir, "dir")
    mkdir(outDir);
end

%% Model definition
% States: x = [h; h_dot; theta; q]
% h      altitude deviation, m
% h_dot  vertical speed, m/s
% theta  pitch angle, rad
% q      pitch rate, rad/s
%
% Control: elevator deflection delta_e, rad. Positive command is aircraft
% nose-up in this simplified sign convention after input gain selection.
A = [ 0      1       0       0;
      0     -0.42    8.50    0.35;
      0      0       0       1;
      0     -0.030  -1.85   -1.20 ];
B = [0; 0.85; 0; 2.40];
C_h = [1 0 0 0];

% Integral state: xi_dot = r_h - h.  Augmented state xa = [x; xi].
Aaug = [A zeros(4,1);
       -C_h 0];
Baug = [B; 0];

Q = diag([0.90, 0.30, 45.0, 6.0, 0.16]);
R = 1.15;
K = lqr(Aaug, Baug, Q, R);

%% Simulation settings
refAltitude = 100;            % m
commandTau = 7.0;             % s, reference governor time constant
gustStart = 14;               % s
gustEnd = 20;                 % s
gustAccel = -0.80;            % m/s^2 vertical acceleration disturbance
deltaLimitDeg = 25;           % elevator saturation
deltaLimit = deg2rad(deltaLimitDeg);
tspan = [0 45];
x0 = zeros(5,1);

params.A = A;
params.B = B;
params.K = K;
params.refAltitude = refAltitude;
params.commandTau = commandTau;
params.gustStart = gustStart;
params.gustEnd = gustEnd;
params.gustAccel = gustAccel;
params.deltaLimit = deltaLimit;

opts = odeset("RelTol",1e-7,"AbsTol",1e-9);
[t, xa] = ode45(@(tt,xx) closed_loop_rhs(tt, xx, params), tspan, x0, opts);

h = xa(:,1);
hdot = xa(:,2);
theta = xa(:,3);
q = xa(:,4);
xi = xa(:,5); %#ok<NASGU>

u = zeros(size(t));
u_unsat = zeros(size(t));
for i = 1:numel(t)
    e_state = xa(i,:)';
    e_state(5) = xa(i,5);
    u_unsat(i) = -K * e_state;
    u(i) = min(max(u_unsat(i), -deltaLimit), deltaLimit);
end

ref = refAltitude * (1 - exp(-t / commandTau));
trackingError = refAltitude - h;
overshoot = max(h) - refAltitude;
settlingBand = 0.02 * refAltitude;
settlingTime = NaN;
for i = 1:numel(t)
    if all(abs(trackingError(i:end)) <= settlingBand)
        settlingTime = t(i);
        break;
    end
end
if isnan(settlingTime)
    settlingTime = t(end);
end

maxPitchDeg = max(abs(rad2deg(theta)));
maxElevatorDeg = max(abs(rad2deg(u)));
steadyError = trackingError(end);
iae = trapz(t, abs(trackingError));

summary = table(refAltitude, overshoot, settlingTime, steadyError, ...
    maxPitchDeg, maxElevatorDeg, iae, ...
    'VariableNames', {'RefAltitude_m','Overshoot_m','SettlingTime_s', ...
    'SteadyError_m','MaxPitch_deg','MaxElevator_deg','IAE_m_s'});
writetable(summary, fullfile(outDir, "simulation_summary.csv"));

gainTable = array2table(K, 'VariableNames', ...
    {'K_h','K_hdot','K_theta','K_q','K_integral'});
writetable(gainTable, fullfile(outDir, "lqr_gain.csv"));

%% Figures
fig1 = figure("Color","w","Position",[100 100 900 560]);
plot(t, h, "LineWidth", 2.0); hold on;
plot(t, ref, "--", "LineWidth", 1.4);
xline(gustStart, ":", "LineWidth", 1.1);
xline(gustEnd, ":", "LineWidth", 1.1);
grid on;
xlabel("Time / s");
ylabel("Altitude deviation / m");
title("Altitude tracking response with gust disturbance");
legend("Altitude response", "Filtered command", "Gust window", "Location", "southeast");
exportgraphics(fig1, fullfile(outDir, "altitude_response.png"), "Resolution", 220);

fig2 = figure("Color","w","Position",[100 100 900 620]);
tiledlayout(2,1, "TileSpacing","compact", "Padding","compact");
nexttile;
plot(t, rad2deg(theta), "LineWidth", 1.8); hold on;
plot(t, rad2deg(q), "LineWidth", 1.5);
grid on;
ylabel("deg, deg/s");
title("Pitch states");
legend("Pitch angle", "Pitch rate", "Location", "northeast");
nexttile;
plot(t, rad2deg(u), "LineWidth", 1.8); hold on;
yline(deltaLimitDeg, "--", "LineWidth", 1.1);
yline(-deltaLimitDeg, "--", "LineWidth", 1.1);
grid on;
xlabel("Time / s");
ylabel("Elevator / deg");
title("Elevator command with saturation limit");
exportgraphics(fig2, fullfile(outDir, "control_states.png"), "Resolution", 220);

fprintf("LQR gain K = [%.6f %.6f %.6f %.6f %.6f]\n", K);
fprintf("Overshoot: %.3f m\n", overshoot);
fprintf("Settling time: %.3f s\n", settlingTime);
fprintf("Steady-state error: %.6f m\n", steadyError);
fprintf("Max pitch: %.3f deg\n", maxPitchDeg);
fprintf("Max elevator: %.3f deg\n", maxElevatorDeg);
fprintf("IAE: %.3f m*s\n", iae);

function dx = closed_loop_rhs(t, xa, p)
    x = xa(1:4);
    xi = xa(5);
    u_unsat = -p.K * [x; xi];
    u = min(max(u_unsat, -p.deltaLimit), p.deltaLimit);

    gust = 0;
    if t >= p.gustStart && t <= p.gustEnd
        gust = p.gustAccel;
    end

    xdot = p.A * x + p.B * u;
    xdot(2) = xdot(2) + gust;
    r = p.refAltitude * (1 - exp(-t / p.commandTau));
    xidot = r - x(1);
    dx = [xdot; xidot];
end
