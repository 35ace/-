function simulate_improved_lqr_aircraft_control(outDir, monteCarloCount)
% Extend the original longitudinal LQI model with a DOB and command governor.
% Example: simulate_improved_lqr_aircraft_control('output/improved_lqr', 30)
if nargin < 1, outDir = fullfile(pwd, 'output', 'improved_lqr'); end
if nargin < 2, monteCarloCount = 30; end
if ~exist(outDir, 'dir'), mkdir(outDir); end
rng(20261009, 'twister');
set(groot, 'defaultFigureVisible', 'off');

p.A = [0 1 0 0; 0 -.42 8.50 .35; 0 0 0 1; 0 -.030 -1.85 -1.20];
p.B = [0; .85; 0; 2.40];
p.E = [0; 1; 0; 0];
p.Ch = [1 0 0 0];
p.Q = diag([.90 .30 45 6 .16]);
p.R = 1.15;
p.K = lqr([p.A zeros(4,1); -p.Ch 0], [p.B; 0], p.Q, p.R);
p.dt = .02;
p.T = 120;
p.tau = .15;
p.uLimit = deg2rad(25);
p.rateLimit = deg2rad(60);
p.pitchLimit = deg2rad(10);
p.pitchPredictionLimit = deg2rad(8);
p.dobBandwidth = 1.5;
p.awGain = 2;
p.safetyPitchLimit = deg2rad(6);
p.safetyLambda = 2;
p.monteCarloSeed = 20262009;
p.governorPeriod = .2;
p.predictionStep = .1;
p.predictionHorizon = 12;
% The gust enters vertical acceleration, not the elevator input channel.
% Solve the steady output-regulation equations instead of using -d_hat/b.
equilibrium = [p.A p.B; p.Ch 0] \ [-p.E; 0];
p.disturbanceEquilibrium = equilibrium;
p.dobFeedforward = p.K(1:4) * equilibrium(1:4) + equilibrium(5);
assert(norm(p.A*equilibrium(1:4)+p.B*equilibrium(5)+p.E) < 1e-10);
assert(abs(p.Ch*equilibrium(1:4)) < 1e-10);

methods = [
    struct('name','LQI','governor',false,'dob',false,'aw',false,'safe',false)
    struct('name','LQI_AW','governor',false,'dob',false,'aw',true,'safe',false)
    struct('name','RG_AW','governor',true,'dob',false,'aw',true,'safe',false)
    struct('name','RG_DOB','governor',true,'dob',true,'aw',false,'safe',false)
    struct('name','RG_DOB_AW','governor',true,'dob',true,'aw',true,'safe',false)
    struct('name','DOB_AW_SAFE','governor',false,'dob',true,'aw',true,'safe',true)
    struct('name','SAFE_RG_DOB_AW','governor',true,'dob',true,'aw',true,'safe',true)
    struct('name','RG_AW_SAFE','governor',true,'dob',false,'aw',true,'safe',true)
    struct('name','RG_DOB_SAFE','governor',true,'dob',true,'aw',false,'safe',true)
];
scenarios = repmat(struct('name','','A',p.A,'B',p.B,'tau',p.tau, ...
    'uLimit',p.uLimit,'rateLimit',p.rateLimit,'noiseScale',0, ...
    'gustScale',1,'persistentGust',0,'reversal',false,'targetAltitude',100),6,1);
scenarios(1).name = 'nominal_gust';
scenarios(2).name = 'strong_persistent_gust';
scenarios(2).gustScale = 1.5;
scenarios(2).persistentGust = -.45;
scenarios(3).name = 'uncertainty_noise';
scenarios(3).A(2,2:4) = p.A(2,2:4).*[1.20 .85 1.15];
scenarios(3).A(4,2:4) = p.A(4,2:4).*[.85 1.15 .80];
scenarios(3).B = .80*p.B;
scenarios(3).noiseScale = 1;
scenarios(4).name = 'actuator_stress';
scenarios(4).tau = .30;
scenarios(4).uLimit = deg2rad(15);
scenarios(4).rateLimit = deg2rad(12);
scenarios(4).gustScale = 1.5;
scenarios(5) = scenarios(4);
scenarios(5).name = 'command_reversal';
scenarios(5).reversal = true;
scenarios(6).name='altitude_hold_gust';
scenarios(6).targetAltitude=0;
scenarios(6).persistentGust=-.45;

original = reproduce_original(p);
writetable(struct2table(original.metrics), fullfile(outDir,'original_reproduction.csv'));
writetable(array2table(p.K,'VariableNames', ...
    {'K_h','K_hdot','K_theta','K_q','K_integral'}), fullfile(outDir,'lqr_gain.csv'));
allMetrics = struct([]);
runs = cell(numel(scenarios), numel(methods));
for s = 1:numel(scenarios)
    noise = make_noise(p, scenarios(s), 100+s);
    g = prepare_governor(p, scenarios(s));
    for m = 1:numel(methods)
        run = simulate_case(p, scenarios(s), methods(m), noise, g);
        runs{s,m} = run;
        if isempty(allMetrics), allMetrics=run.metrics;
        else, allMetrics(end+1)=run.metrics; end %#ok<AGROW>
        export_trace(run, fullfile(outDir, [scenarios(s).name '_' methods(m).name '.csv']));
    end
    fprintf('Completed scenario %s\n', scenarios(s).name);
end
writetable(struct2table(allMetrics), fullfile(outDir,'comparison_metrics.csv'));
plot_comparisons(p, scenarios, methods, runs, outDir);

mcMetrics = struct([]);
uncertaintyDraws = zeros(monteCarloCount,8);
for seed = 1:monteCarloCount
    rng(p.monteCarloSeed+seed, 'twister');
    scale = .8 + .4*rand(1,6);
    s = scenarios(3);
    s.name = 'monte_carlo';
    s.A = p.A;
    s.A(2,2:4) = p.A(2,2:4).*scale(1:3);
    s.A(4,2:4) = p.A(4,2:4).*scale(4:6);
    bScale = .8 + .4*rand;
    s.B = bScale*p.B;
    s.gustScale = .75 + .75*rand;
    s.persistentGust = -.30;
    uncertaintyDraws(seed,:) = [scale bScale s.gustScale];
    noise = make_noise(p,s,2000+seed);
    g = prepare_governor(p,s);
    for m = [1 3 6 7]
        run = simulate_case(p,s,methods(m),noise,g);
        row = run.metrics;
        row.Seed = seed;
        if isempty(mcMetrics), mcMetrics=row;
        else, mcMetrics(end+1)=row; end %#ok<AGROW>
    end
end
if monteCarloCount > 0
    writetable(struct2table(mcMetrics), fullfile(outDir,'monte_carlo_metrics.csv'));
    writetable(array2table([(1:monteCarloCount)' uncertaintyDraws], ...
        'VariableNames',{'Seed','A22Scale','A23Scale','A24Scale', ...
        'A42Scale','A43Scale','A44Scale','BScale','GustScale'}), ...
        fullfile(outDir,'monte_carlo_draws.csv'));
    plot_monte_carlo(mcMetrics,methods,outDir);
end

% Repeat one deterministic run at half step to measure integration sensitivity.
fineP = p; fineP.dt = p.dt/2;
fineS = scenarios(1);
fineRun = simulate_case(fineP,fineS,methods(7),make_noise(fineP,fineS,101), ...
    prepare_governor(fineP,fineS));
coarse = runs{1,7};
fineH = interp1(fineRun.t,fineRun.x(:,1),coarse.t);
finePitch = interp1(fineRun.t,fineRun.x(:,3),coarse.t);
integration = table(max(abs(fineH-coarse.x(:,1))), ...
    max(abs(rad2deg(finePitch-coarse.x(:,3)))), ...
    'VariableNames',{'MaxAltitudeDifference_m','MaxPitchDifference_deg'});
writetable(integration,fullfile(outDir,'integration_check.csv'));
validation = struct('MatlabVersion',version,'SampleTime_s',p.dt, ...
    'Duration_s',p.T,'MonteCarloCount',monteCarloCount, ...
    'RandomSeed',20261009,'NominalClosedLoopPoles', ...
    eig([p.A zeros(4,1);-p.Ch 0]-[p.B;0]*p.K), ...
    'DisturbanceEquilibrium',equilibrium,'DOBFeedforward',p.dobFeedforward, ...
    'PitchDesignLimit_deg',10,'PitchPredictionLimit_deg',8, ...
    'PredictionHorizon_s',p.predictionHorizon,'GovernorPeriod_s',p.governorPeriod, ...
    'DOBBandwidth_rad_s',p.dobBandwidth,'AntiWindupGain_per_s',p.awGain);
validation.SafetyPitchLimit_deg=rad2deg(p.safetyPitchLimit);
validation.SafetyLambda_per_s=p.safetyLambda;
validation.MonteCarloParameterSeed=p.monteCarloSeed;
validation.MonteCarloNoiseSeedBase=2000;
% Store complex poles as separate real and imaginary arrays for portable JSON.
validation.NominalClosedLoopPolesReal = real(validation.NominalClosedLoopPoles);
validation.NominalClosedLoopPolesImag = imag(validation.NominalClosedLoopPoles);
validation = rmfield(validation,'NominalClosedLoopPoles');
fid = fopen(fullfile(outDir,'configuration.json'),'w');
fprintf(fid,'%s',jsonencode(validation,PrettyPrint=true)); fclose(fid);
save(fullfile(outDir,'simulation_workspace.mat'),'p','methods','scenarios','runs','mcMetrics');
assert(all(isfinite([allMetrics.TargetIAE_m_s])), 'Nonfinite simulation metric');
assert(all([allMetrics.MaxElevator_deg] <= rad2deg(p.uLimit)+1e-6));
for s=1:numel(scenarios)
    for m=1:numel(methods)
        assert(runs{s,m}.metrics.MaxElevator_deg<=rad2deg(scenarios(s).uLimit)+1e-6);
        assert(runs{s,m}.metrics.MaxElevatorRate_deg_s<=rad2deg(scenarios(s).rateLimit)+1e-5);
    end
end
assert(integration.MaxAltitudeDifference_m < .1,'Integration sensitivity is too large');
disp(struct2table(allMetrics));
fprintf('Results saved in %s\n',outDir);
end

function run = reproduce_original(p)
pa = p;
rhs = @(t,z) original_rhs(t,z,pa);
opts = odeset('RelTol',1e-7,'AbsTol',1e-9);
[t,z] = ode45(rhs,[0 45],zeros(5,1),opts);
u = max(min(-z*p.K',p.uLimit),-p.uLimit);
err = 100-z(:,1);
lastOutside = find(abs(err)>2,1,'last');
settling = NaN;
if isempty(lastOutside), settling=0;
elseif lastOutside<numel(t), settling=t(lastOutside+1); end
run.metrics = struct('FinalError_m',err(end),'MaxPitch_deg',max(abs(rad2deg(z(:,3)))), ...
    'MaxElevator_deg',max(abs(rad2deg(u))),'TargetIAE_m_s',trapz(t,abs(err)), ...
    'SettlingTime_s',settling,'SignedPeakMinusTarget_m',max(z(:,1))-100, ...
    'Overshoot_m',max(0,max(z(:,1))-100));
end

function dz = original_rhs(t,z,p)
u = max(min(-p.K*z,p.uLimit),-p.uLimit);
d = -.8*(t>=14 && t<=20);
dz = [p.A*z(1:4)+p.B*u+p.E*d;100*(1-exp(-t/7))-z(1)];
end

function noise = make_noise(p,s,seed)
rng(seed,'twister');
sigma = [.03 .025 deg2rad(.05) deg2rad(.08)];
noise = randn(round(p.T/p.dt)+1,4).*sigma*s.noiseScale;
end

function g = prepare_governor(p,s)
% Exact sampled prediction of the nominal unsaturated 6-state closed loop.
Ac = [p.A zeros(4,1) p.B; -p.Ch 0 0; ...
    -p.K(1:4)/s.tau -p.K(5)/s.tau -1/s.tau];
Gc = [zeros(4,1) p.E;1 0;0 p.dobFeedforward/s.tau];
M = expm([Ac Gc;zeros(2,8)]*p.predictionStep);
F = M(1:6,1:6); H = M(1:6,7:8);
Cu = [-p.K 0];
C = [0 0 1 0 0 0; 0 0 0 0 0 1; Cu; ...
    (Cu-[0 0 0 0 0 1])/s.tau];
D = zeros(4,2); D(3,2)=p.dobFeedforward; D(4,2)=p.dobFeedforward/s.tau;
steps = round(p.predictionHorizon/p.predictionStep);
g.P = zeros(4*steps,6); g.G = zeros(4*steps,2);
Fp = eye(6); Hp = zeros(6,2);
for j=1:steps
    Fp=F*Fp; Hp=F*Hp+H;
    idx=(j-1)*4+(1:4);
    g.P(idx,:)=C*Fp; g.G(idx,:)=C*Hp+D;
end
g.limits = repmat([p.pitchPredictionLimit;s.uLimit;s.uLimit;s.rateLimit],steps,1);
end

function [reference,feasible] = govern(w,previous,target,dhat,g)
base = g.P*w + g.G*[previous;dhat];
direction = g.G(:,1)*(target-previous);
lower=0; upper=1;
for j=1:numel(base)
    if abs(direction(j))<1e-12
        if abs(base(j))>g.limits(j)+1e-9, lower=2; break; end
    else
        bounds=sort([(-g.limits(j)-base(j))/direction(j), ...
            (g.limits(j)-base(j))/direction(j)]);
        lower=max(lower,bounds(1)); upper=min(upper,bounds(2));
    end
end
feasible=lower<=upper;
if feasible
    alpha=max(0,min(1,upper));
else
    % Explicit fallback when the finite-horizon nominal prediction is infeasible.
    % Count it in the results; it is not a robust invariant-set guarantee.
    candidates=linspace(0,1,21);
    violation=max(abs(base+direction*candidates)./g.limits,[],1);
    [~,best]=min(violation); alpha=candidates(best);
end
reference=previous+alpha*(target-previous);
end

function run = simulate_case(p,s,m,noise,g)
t=(0:p.dt:p.T)'; n=numel(t);
z=zeros(n,7); % [h v theta q xi actual_elevator dob_internal]
target=s.targetAltitude*ones(n,1);
if s.reversal, target(t>=55)=40; end
reference=zeros(n,1); dhat=zeros(n,1); command=zeros(n,1);
gust=zeros(n,1); infeasible=zeros(n,1); rateLimited=zeros(n,1);
safetyActive=zeros(n,1); safetyInfeasible=zeros(n,1);
governorSteps=round(p.governorPeriod/p.dt);
r=0;
for k=1:n
    d=gust_value(t(k),s); gust(k)=d;
    measurement=z(k,1:4)'+noise(k,:)';
    dh=m.dob*(z(k,7)+p.dobBandwidth*measurement(2));
    if m.governor
        if mod(k-1,governorSteps)==0
            [r,ok]=govern([measurement;z(k,5:6)'],r,target(k),dh,g);
            infeasible(k)=~ok;
        end
    elseif ~s.reversal || t(k)<55
        r=s.targetAltitude*(1-exp(-t(k)/7));
    else
        start=s.targetAltitude*(1-exp(-55/7));
        r=40+(start-40)*exp(-(t(k)-55)/7);
    end
    reference(k)=r; dhat(k)=dh;
    command(k)=-p.K*[measurement;z(k,5)]+p.dobFeedforward*dh;
    limited=max(min(command(k),s.uLimit),-s.uLimit);
    rateLimited(k)=abs((limited-z(k,6))/s.tau)>s.rateLimit+1e-9;
    [~,safetyActive(k),safetyInfeasible(k)]=engineering_rhs( ...
        z(k,:)',r,d,noise(k,:)',p,s,m);
    if k<n
        f=@(zz) engineering_rhs(zz,r,d,noise(k,:)',p,s,m);
        a=f(z(k,:)'); b=f(z(k,:)'+p.dt*a/2);
        c=f(z(k,:)'+p.dt*b/2); e=f(z(k,:)'+p.dt*c);
        z(k+1,:)=z(k,:)+p.dt*(a+2*b+2*c+e)'/6;
    end
end
run=struct('t',t,'x',z(:,1:4),'xi',z(:,5),'u',z(:,6), ...
    'command',command,'reference',reference,'target',target,'gust',gust, ...
    'dhat',dhat,'infeasible',infeasible,'safetyActive',safetyActive, ...
    'safetyInfeasible',safetyInfeasible);
tracking=reference-z(:,1);
targetError=target-z(:,1);
checkFrom=0;
if s.reversal, checkFrom=55; end
lastOutside=find(abs(targetError)>2 & t>=checkFrom,1,'last');
settling=NaN;
if isempty(lastOutside), settling=checkFrom;
elseif lastOutside<n, settling=t(lastOutside+1)-checkFrom; end
post=t>=max(65,checkFrom);
rate=diff(z(:,6))/p.dt;
run.metrics=struct('Scenario',s.name,'Method',m.name, ...
    'TargetIAE_m_s',trapz(t,abs(targetError)), ...
    'ReferenceRMSE_m',sqrt(trapz(t,tracking.^2)/p.T), ...
    'FinalError_m',targetError(end),'SettlingTime_s',settling, ...
    'Overshoot_m',max(0,max(z(:,1))-s.targetAltitude), ...
    'MaxAbsoluteTargetError_m',max(abs(targetError)), ...
    'MaxPitch_deg',max(abs(rad2deg(z(:,3)))), ...
    'PitchViolationDuration_s',p.dt*sum(abs(z(:,3))>p.pitchLimit), ...
    'SafetyEnvelopeViolationDuration_s',p.dt*sum(abs(z(:,3))>p.safetyPitchLimit), ...
    'MaxElevator_deg',max(abs(rad2deg(z(:,6)))), ...
    'MaxElevatorRate_deg_s',max(abs(rad2deg(rate))), ...
    'CommandSaturationDuration_s',p.dt*sum(abs(command)>s.uLimit), ...
    'RateLimitDuration_s',p.dt*sum(rateLimited), ...
    'GovernorInfeasibleUpdates',sum(infeasible), ...
    'SafetyActiveDuration_s',p.dt*sum(safetyActive), ...
    'SafetyInfeasibleDuration_s',p.dt*sum(safetyInfeasible), ...
    'ElevatorTotalVariation_deg',sum(abs(rad2deg(diff(z(:,6))))), ...
    'PostGustTargetRMSE_m',sqrt(mean(targetError(post).^2)), ...
    'GustWindowTargetRMSE_m',sqrt(mean(targetError(t>=45 & t<65).^2)), ...
    'DOB_RMSE_m_s2',sqrt(mean((dhat-gust).^2)));
end

function [dz,safetyActive,safetyInfeasible] = engineering_rhs(z,r,d,noise,p,s,m)
measurement=z(1:4)+noise;
dhat=m.dob*(z(7)+p.dobBandwidth*measurement(2));
uc=-p.K*[measurement;z(5)]+p.dobFeedforward*dhat;
amplitudeLimited=max(min(uc,s.uLimit),-s.uLimit);
actuatorRate=max(min((amplitudeLimited-z(6))/s.tau,s.rateLimit),-s.rateLimit);
safetyActive=false; safetyInfeasible=false;
if m.safe
    % Third-order exponential barrier for pitch with first-order actuator.
    % Model mismatch is addressed by a 4-degree margin and measured tests.
    q=measurement(4); theta=measurement(3); lambda=p.safetyLambda;
    acceleration=p.A(4,:)*measurement+p.B(4)*z(6);
    jerkDrift=p.A(4,:)*(p.A*measurement+p.B*z(6)+p.E*dhat);
    common=-3*lambda*acceleration-3*lambda^2*q-jerkDrift;
    lower=(common-lambda^3*(p.safetyPitchLimit+theta))/p.B(4);
    upper=(common+lambda^3*(p.safetyPitchLimit-theta))/p.B(4);
    lower=max(lower,max(-s.rateLimit,(-s.uLimit-z(6))/p.dt));
    upper=min(upper,min(s.rateLimit,(s.uLimit-z(6))/p.dt));
    originalRate=actuatorRate;
    if lower<=upper
        actuatorRate=min(max(actuatorRate,lower),upper);
    else
        safetyInfeasible=true;
        physicalLower=max(-s.rateLimit,(-s.uLimit-z(6))/p.dt);
        physicalUpper=min(s.rateLimit,(s.uLimit-z(6))/p.dt);
        actuatorRate=min(max((lower+upper)/2,physicalLower),physicalUpper);
    end
    safetyActive=abs(actuatorRate-originalRate)>1e-8;
end
realizable=z(6)+s.tau*actuatorRate;
integralRate=r-measurement(1);
if m.aw
    integralRate=integralRate+p.awGain*(realizable-uc)/(-p.K(5));
end
observerRate=0;
if m.dob
    observerRate=-p.dobBandwidth*(z(7)+p.dobBandwidth*measurement(2) ...
        +p.A(2,:)*measurement+p.B(2)*z(6));
end
dz=[s.A*z(1:4)+s.B*z(6)+p.E*d;integralRate;actuatorRate;observerRate];
end

function d = gust_value(t,s)
d=-.8*s.gustScale*(t>=14 && t<20);
if t>=45 && t<65, d=d+s.persistentGust; end
end

function export_trace(run,path)
T=table(run.t,run.target,run.reference,run.x(:,1),run.x(:,2), ...
    rad2deg(run.x(:,3)),rad2deg(run.x(:,4)),rad2deg(run.u), ...
    rad2deg(run.command),run.gust,run.dhat,run.infeasible, ...
    run.xi,run.safetyActive,run.safetyInfeasible, ...
    'VariableNames',{'Time_s','Target_m','GovernedReference_m','Altitude_m', ...
    'VerticalSpeed_m_s','Pitch_deg','PitchRate_deg_s','Elevator_deg', ...
    'RawCommand_deg','Gust_m_s2','EstimatedGust_m_s2','GovernorInfeasible', ...
    'IntegralError_m_s','SafetyActive','SafetyInfeasible'});
writetable(T,path);
end

function plot_comparisons(p,scenarios,methods,runs,outDir)
colors=[.25 .25 .25; .72 .34 .12; .15 .42 .73; .56 .35 .62; .68 .55 .12; .12 .55 .37; .05 .48 .52; .62 .24 .32; .33 .4 .55];
labels=strrep({methods.name},'_',' + ');
for s=1:numel(scenarios)
    fig=figure('Color','w','Position',[100 100 1100 800]);
    tiledlayout(3,1,'TileSpacing','compact','Padding','compact');
    nexttile; hold on;
    for m=[1 3 6 7]
        run=runs{s,m}; plot(run.t,run.x(:,1),'Color',colors(m,:),'LineWidth',1.5);
    end
    plot(run.t,run.target,'k--','LineWidth',1);
    plot(run.t,run.reference,':','Color',colors(7,:),'LineWidth',1.5);
    grid on; ylabel('Altitude / m');
    title(strrep(scenarios(s).name,'_',' '));
    legend([labels([1 3 6 7]) {'Requested target','Full-method reference'}], ...
        'Location','eastoutside');
    nexttile; hold on;
    for m=[1 3 6 7]
        run=runs{s,m}; plot(run.t,rad2deg(run.x(:,3)),'Color',colors(m,:),'LineWidth',1.5);
    end
    yline(rad2deg(p.pitchLimit),'k--'); yline(-rad2deg(p.pitchLimit),'k--');
    ylabel('Pitch / deg'); grid on;
    nexttile; hold on;
    for m=[1 3 6 7]
        run=runs{s,m}; plot(run.t,rad2deg(run.u),'Color',colors(m,:),'LineWidth',1.5);
    end
    yline(rad2deg(scenarios(s).uLimit),'k--');
    yline(-rad2deg(scenarios(s).uLimit),'k--');
    ylabel('Elevator / deg'); xlabel('Time / s'); grid on;
    exportgraphics(fig,fullfile(outDir,[scenarios(s).name '_comparison.png']),'Resolution',180);
    close(fig);
end
run=runs{6,7};
fig=figure('Color','w','Position',[100 100 1050 620]);
tiledlayout(2,1,'TileSpacing','compact','Padding','compact');
nexttile; plot(run.t,run.gust,'k--','LineWidth',1.5); hold on;
plot(run.t,run.dhat,'Color',colors(7,:),'LineWidth',1.5);
grid on; ylabel('Acceleration / m s^{-2}'); legend('Injected gust','DOB estimate');
title('Disturbance estimation and constrained command');
nexttile; plot(run.t,run.target,'k--','LineWidth',1); hold on;
plot(run.t,run.reference,'Color',colors(3,:),'LineWidth',1.5);
plot(run.t,run.x(:,1),'Color',colors(7,:),'LineWidth',1.5);
grid on; ylabel('Altitude / m'); xlabel('Time / s');
legend('Requested target','Governed reference','Altitude');
exportgraphics(fig,fullfile(outDir,'disturbance_observer.png'),'Resolution',180); close(fig);
fig=figure('Color','w','Position',[100 100 1050 620]);
tiledlayout(2,1,'TileSpacing','compact','Padding','compact');
nexttile; hold on;
selected=[1 5 6 8 9 7];
for m=selected
    run=runs{5,m}; plot(run.t,run.x(:,1),'Color',colors(m,:),'LineWidth',1.3);
end
plot(run.t,run.target,'k--'); ylabel('Altitude / m'); grid on;
legend([labels(selected) {'Requested target'}],'Location','eastoutside'); title('Ablation under command reversal');
nexttile; hold on;
for m=selected
    run=runs{5,m}; plot(run.t,rad2deg(run.x(:,3)),'Color',colors(m,:),'LineWidth',1.3);
end
yline(10,'k--'); yline(-10,'k--'); grid on;
ylabel('Pitch / deg'); xlabel('Time / s');
exportgraphics(fig,fullfile(outDir,'ablation_comparison.png'),'Resolution',180); close(fig);
end

function plot_monte_carlo(rows,methods,outDir)
fig=figure('Color','w','Position',[100 100 1050 700]);
tiledlayout(2,2,'TileSpacing','compact','Padding','compact');
selected=[1 3 6 7];
fields={'MaxPitch_deg','TargetIAE_m_s','SettlingTime_s','ElevatorTotalVariation_deg'};
ylabels={'Peak pitch / deg','Target IAE / m s','Settling time / s','Elevator variation / deg'};
colors=[.25 .25 .25;.15 .42 .73;.12 .55 .37;.05 .48 .52];
for j=1:4
    nexttile; hold on;
    for m=1:4
        data=rows(strcmp({rows.Method},methods(selected(m)).name));
        scatter([data.Seed],[data.(fields{j})],20,colors(m,:),'filled');
    end
    if j==1, yline(10,'k--','Design threshold'); end
    grid on; xlabel('Paired parameter draw'); ylabel(ylabels{j});
end
legend({'LQI','RG + AW','DOB + AW + SAFE','Full method'},'Location','southoutside','Orientation','horizontal');
exportgraphics(fig,fullfile(outDir,'monte_carlo_comparison.png'),'Resolution',180);
close(fig);
end
