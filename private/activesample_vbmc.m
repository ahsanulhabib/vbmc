function [optimState,vp,gp,timer] = ...
    activesample_vbmc(optimState,Ns,funwrapper,vp,vp_old,gp,stats,timer,options)
%ACTIVESAMPLE_VBMC Actively sample points iteratively based on acquisition function.

NSsearch = options.NSsearch;    % Number of points for acquisition fcn
t_func = 0;

time_active = tic;

if isempty(gp)
    
    % No GP yet, just use provided points or sample from plausible box
    [optimState,t_func] = ...
        initdesign_vbmc(optimState,Ns,funwrapper,t_func,options);
    
else                    % Active uncertainty sampling
    
    SearchAcqFcn = options.SearchAcqFcn;
    
    if options.AcqHedge && numel(SearchAcqFcn) > 1        
        % Choose acquisition function via hedge strategy
        optimState.hedge = acqhedge_vbmc('acq',optimState.hedge,[],options);
        idxAcq = optimState.hedge.chosen;        
    end
    
    % Compute time cost (used by some acquisition functions)
    if optimState.iter > 2
        deltaNeff = max(1,stats.Neff(optimState.iter-1) - stats.Neff(optimState.iter-2));
    else
        deltaNeff = stats.Neff(1);
    end
    timer_iter = stats.timer(optimState.iter-1);
    % t_base = timer_iter.activeSampling + timer_iter.variationalFit + timer_iter.finalize;
    gpTrain_vec = [stats.timer.gpTrain];

    if options.ActiveVariationalSamples > 0
        options_activevar = options;
        options_activevar.TolWeight = 0;
        options_activevar.NSentFine = options.NSent;
        options_activevar.ELCBOmidpoint = false;
        Ns_activevar = options.ActiveVariationalSamples;
    end
    
    if options.ActiveSampleFullUpdate && Ns > 1
        RecomputeVarPost_old = optimState.RecomputeVarPost;
        entropy_alpha_old = optimState.entropy_alpha;
        
        % optimState.RecomputeVarPost = false;
        options_update = options;
        % options_update.GPRetrainThreshold = Inf;
        % options_update.GPSampleThin = 1;
        options_update.GPTolOpt = options.GPTolOptActive;
        options_update.GPTolOptMCMC = options.GPTolOptMCMCActive;
        options_update.TolWeight = 0;
        options_update.NSent = options.NSentActive;
        options_update.NSentFast = options.NSentFastActive;
        options_update.NSentFine = options.NSentFineActive;
        
%        options_update.TolFunStochastic = 3*options.TolFunStochastic;
%        options_update.DetEntTolOpt = 3*options.DetEntTolOpt;
%        options_update.NSgpMaxMain = 3;
%        options_update.NSgpMaxWarmup = 3;
        hypstruct = [];
    end

    % if Ns > 1; vp_old = vp; end
    
    for is = 1:Ns
        
        optimState.N = optimState.Xn;  % Number of training inputs
        optimState.Neff = sum(optimState.nevals(optimState.X_flag));        
                
        if options.ActiveVariationalSamples > 0
            [vp,~,output] = vpsample_vbmc(Ns_activevar,0,vp,gp,optimState,options_activevar,options.ScaleLowerBound);
            if isfield(output,'stepsize'); optimState.mcmc_stepsize = output.stepsize; end
%            output.stepsize
%            ELCBOWeight = sqrt(0.2*2*log(vp.D*optimState.Neff^2*pi^2/(6*0.1)));
%            options_temp.ELCBOWeight = -log(rand())*ELCBOWeight;
%            vp = vpoptimize_vbmc(0,1,vp,gp,vp.K,optimState,options_temp,0);
%            vbmc_iterplot(vp,gp,optimState,stats,stats.elbo(end));
%            vbmc_iterplot(vp_old,gp,optimState,stats,stats.elbo(end));            
        end
                
        Nextra = evaloption_vbmc(options.SampleExtraVPMeans,vp.K);        
        if Nextra > 0
            vp_base = vp;
            NsFromGP = 2e3;
            Nextra = evaloption_vbmc(options.SampleExtraVPMeans,vp.K);
            x0 = vbmc_rnd(vp,1,0);
            xx = gplite_sample(gp,NsFromGP,x0);
            OptimizeMu = vp.optimize_mu;
            vp.optimize_mu = false;
            vp.K = vp.K + Nextra;
            vp.mu = [vp.mu,xx(round(linspace(1,size(xx,1),Nextra)),:)'];
            vp.sigma = [vp.sigma,exp(mean(log(vp.sigma)))*ones(1,Nextra)];
            vp.w = [vp.w,exp(mean(log(vp.w)))*ones(1,Nextra)];
            vp.w = vp.w(:)'/sum(vp.w);
            options_vp = options;
            options_vp.NSent = 0;
            options_vp.NSentFast = 0;
            options_vp.NSentFine = 0;
            vp = vpoptimize_vbmc(0,1,vp,gp,[],optimState,options_vp,0);
            vp.optimize_mu = OptimizeMu;
        end
        
        if ~options.AcqHedge
            idxAcq = randi(numel(SearchAcqFcn));
        end

        %% Pre-computations for acquisition functions
        
        % Re-evaluate variance of the log joint if requested
        if isfield(optimState.acqInfo{idxAcq},'compute_varlogjoint') ...
                && optimState.acqInfo{idxAcq}.compute_varlogjoint
            [~,~,varF] = gplogjoint(vp,gp,0,0,0,1);
            optimState.varlogjoint_samples = varF;
        end
        
        % Evaluate noise at each training point
        Ns_gp = numel(gp.post);
        sn2new = zeros(size(gp.X,1),Ns_gp);
        for s = 1:Ns_gp
            hyp_noise = gp.post(s).hyp(gp.Ncov+1:gp.Ncov+gp.Nnoise); % Get noise hyperparameters 
            if isfield(optimState,'S')
                s2 = (optimState.S(optimState.X_flag).^2).*optimState.nevals(optimState.X_flag);
            else
                s2 = [];
            end
            s2 = noiseshaping_vbmc(s2,gp.y,options);
            sn2new(:,s) = gplite_noisefun(hyp_noise,gp.X,gp.noisefun,gp.y,s2);
        end
        gp.sn2new = mean(sn2new,2);
        
        % Evaluate GP input length scale (use geometric mean)
        D = size(gp.X,2);
        ln_ell = zeros(D,Ns_gp);
        for s = 1:Ns_gp; ln_ell(:,s) = gp.post(s).hyp(1:D); end
        optimState.gplengthscale = exp(mean(ln_ell,2))';
        
        % Rescale GP training inputs by GP length scale
        gp.X_rescaled = bsxfun(@rdivide,gp.X,optimState.gplengthscale);
        
        % Algorithmic time per iteration (from last iteration)
        t_base = timer_iter.activeSampling + timer_iter.variationalFit + timer_iter.finalize + timer_iter.gpTrain;
        
        % Estimated increase in cost for a new training input
        if optimState.iter > 3
            len = 10;
            xx = log(stats.N(max(end-len,ceil(end/2)):end));
            yy = log(gpTrain_vec(max(end-len,ceil(end/2)):end));
            if numel(unique(xx)) > 1
                p = polyfit(xx,yy,1);
                gpTrain_diff = diff(exp(polyval(p,log([stats.N(end),stats.N(end)+1]))));
            else
                gpTrain_diff = 0;
            end
        else
            gpTrain_diff = 0;
        end
        
        % Algorithmic cost per function evaluation
        optimState.t_algoperfuneval = t_base/deltaNeff + max(0,gpTrain_diff);
        % [t_base/deltaNeff,gpTrain_diff]
        
        
        %% Start active search
        
        optimState.acqrand = rand();    % Seed for random acquisition fcn
        
        % Create search set from cache and randomly generated
        [Xsearch,idx_cache] = getSearchPoints(NSsearch,optimState,vp,options);
        Xsearch = real2int_vbmc(Xsearch,vp.trinfo,optimState.integervars);
        
        % Evaluate acquisition function
        acq_fast = SearchAcqFcn{idxAcq}(Xsearch,vp,gp,optimState,0);

        if options.SearchCacheFrac > 0
            [~,ord] = sort(acq_fast,'ascend');
            optimState.SearchCache = Xsearch(ord,:);
            idx = ord(1);
        else
            [~,idx] = min(acq_fast);
        end
        % idx/numel(acq_fast)
        Xacq = Xsearch(idx,:);
        idx_cache_acq = idx_cache(idx);
        
        % Remove selected points from search set
        Xsearch(idx,:) = []; idx_cache(idx) = [];
        % [size(Xacq,1),size(Xacq2,1)]
        
        % Additional search via optimization
        if ~strcmpi(options.SearchOptimizer,'none')
            fval_old = SearchAcqFcn{idxAcq}(Xacq(1,:),vp,gp,optimState,0);
            x0 = real2int_vbmc(Xacq(1,:),vp.trinfo,optimState.integervars);
            xrange = max(gp.X) - min(gp.X);
            LB = min([gp.X;x0]) - 0.1*xrange; UB = max([gp.X;x0]) + 0.1*xrange;
            if isfield(optimState.acqInfo{idxAcq},'log_flag') ...
                    && optimState.acqInfo{idxAcq}.log_flag
                TolFun = 1e-2;
            else
                TolFun = max(1e-12,abs(fval_old*1e-3));
            end
            
            switch lower(options.SearchOptimizer)
                case 'cmaes'
                    if options.SearchCMAESVPInit
                        [~,Sigma] = vbmc_moments(vp,0);                        
                        %[~,idx_nearest] = min(sum(bsxfun(@minus,vp.mu,x0(:)).^2,1));
                        %Sigma = diag(vp.sigma(idx_nearest)^2.*vp.lambda.^2);                        
                    else
                        X_hpd = gethpd_vbmc(gp.X,gp.y,options.HPDFrac);
                        Sigma = cov(X_hpd,1);
                    end
                    insigma = sqrt(diag(Sigma));
                    cmaes_opts = options.CMAESopts;
                    cmaes_opts.TolFun = TolFun;
                    cmaes_opts.MaxFunEvals = options.SearchMaxFunEvals;
                    cmaes_opts.LBounds = LB(:);
                    cmaes_opts.UBounds = UB(:);                
                    [xsearch_optim,fval_optim,~,~,out_optim,bestever] = cmaes_modded(func2str(SearchAcqFcn{idxAcq}),x0(:),insigma,cmaes_opts,vp,gp,optimState,1);
                    if options.SearchCMAESbest
                        xsearch_optim = bestever.x;
                        fval_optim = bestever.f;
                    end
                    % out_optim.evals
                    xsearch_optim = xsearch_optim';
                case 'fmincon'
                    fmincon_opts.Display = 'off';
                    fmincon_opts.TolFun = TolFun;
                    fmincon_opts.MaxFunEvals = options.SearchMaxFunEvals;
                    [xsearch_optim,fval_optim,~,out_optim] = fmincon(@(x) SearchAcqFcn{idxAcq}(x,vp,gp,optimState,0),x0,[],[],[],[],LB,UB,[],fmincon_opts);
                    % out_optim
                case 'bads'
                    bads_opts.Display = 'off';
                    bads_opts.TolFun = TolFun;
                    bads_opts.MaxFunEvals = options.SearchMaxFunEvals;
                    [xsearch_optim,fval_optim,~,out_optim] = bads(@(x) SearchAcqFcn{idxAcq}(x,vp,gp,optimState,0),x0,LB,UB,LB,UB,[],bads_opts);
                otherwise
                    error('vbmc:UnknownOptimizer','Unknown acquisition function search optimization method.');            
            end        

            if fval_optim < fval_old            
                Xacq(1,:) = real2int_vbmc(xsearch_optim,vp.trinfo,optimState.integervars);
                idx_cache_acq(1) = 0;
                % idx_cache = [idx_cache(:); 0];
                % Double check if the cache indexing is correct
            end
        end
        
%         % Finish search with a few MCMC iterations
%         if 1 || options.SearchMCMC                
%             mcmc_fun = @(x) log(-SearchAcqFcn{idxAcq}(x,vp,gp,optimState,0)/0.01);
%             Widths = max(max(sqrt(diag(Sigma)'),0.1),optimState.gplengthscale);
%             Ns = 1;
%             sampleopts.Thin = 1;
%             sampleopts.Burnin = 10;
%             sampleopts.Display = 'off';
%             sampleopts.Diagnostics = false;
%             LB = -Inf; UB = Inf;
%             [samples,fvals,exitflag,output] = ...
%                 slicesamplebnd_vbmc(mcmc_fun,Xacq(1,:),Ns,Widths,LB,UB,sampleopts);
%             Xacq(1,:) = samples;
%             fval_mcmc = SearchAcqFcn{idxAcq}(Xacq(1,:),vp,gp,optimState,0);
%         end        
        
        if options.UncertaintyHandling && options.MaxRepeatedObservations > 0            
            if optimState.RepeatedObservationsStreak >= options.MaxRepeatedObservations
                % Maximum number of consecutive repeated observations 
                % (to prevent getting stuck in a wrong belief state)
                optimState.RepeatedObservationsStreak = 0;
            else            
                % Re-evaluate acquisition function on training set
                X_train = get_traindata_vbmc(optimState,options);

                % Disable variance-based regularization first
                oldflag = optimState.VarianceRegularizedAcqFcn;
                optimState.VarianceRegularizedAcqFcn = false;
                % Use current cost of GP instead of future cost
                old_t_algoperfuneval = optimState.t_algoperfuneval;
                optimState.t_algoperfuneval = t_base/deltaNeff;
                acq_train = SearchAcqFcn{idxAcq}(X_train,vp,gp,optimState,0);
                optimState.VarianceRegularizedAcqFcn = oldflag;
                optimState.t_algoperfuneval = old_t_algoperfuneval;            
                [acq_train,idx_train] = min(acq_train);            

                acq_now = SearchAcqFcn{idxAcq}(Xacq(1,:),vp,gp,optimState,0);

                % [acq_train,acq_now]

                if acq_train < options.RepeatedAcqDiscount*acq_now
                    Xacq(1,:) = X_train(idx_train,:);
                    optimState.RepeatedObservationsStreak = optimState.RepeatedObservationsStreak + 1;
                else
                    optimState.RepeatedObservationsStreak = 0;
                end
            end
        end
        
        y_orig = [NaN; optimState.Cache.y_orig(:)]; % First position is NaN (not from cache)
        yacq = y_orig(idx_cache_acq+1);
        idx_nn = ~isnan(yacq);
        if any(idx_nn)
            yacq(idx_nn) = yacq(idx_nn) + warpvars_vbmc(Xacq(idx_nn,:),'logp',optimState.trinfo);
        end
        
        xnew = Xacq(1,:);
        idxnew = 1;
        
        % See if chosen point comes from starting cache
        idx = idx_cache_acq(idxnew);
        if idx > 0; y_orig = optimState.Cache.y_orig(idx); else; y_orig = NaN; end
        timer_func = tic;
        if isnan(y_orig)    % Function value is not available, evaluate
            try
                [ynew,optimState,idx_new] = funlogger_vbmc(funwrapper,xnew,optimState,'iter');
            catch func_error
                pause
            end
        else
            [ynew,optimState,idx_new] = funlogger_vbmc(funwrapper,xnew,optimState,'add',y_orig);
            % Remove point from starting cache
            optimState.Cache.X_orig(idx,:) = [];
            optimState.Cache.y_orig(idx) = [];
        end
        t_func = t_func + toc(timer_func);
            
        % ynew = outputwarp(ynew,optimState,options);
        if isfield(optimState,'S')
            s2new = optimState.S(idx_new)^2;
        else
            s2new = [];
        end
        tnew = optimState.funevaltime(idx_new);
        
        if 1
            if ~isfield(optimState,'acqtable'); optimState.acqtable = []; end
            [~,~,fmu,fs2] = gplite_pred(gp,xnew);
            v = [idxAcq,ynew,fmu,sqrt(fs2)];
            optimState.acqtable = [optimState.acqtable; v];
        end
        
        if Nextra > 0
            vp = vp_base;
        end
        
        if is < Ns
            
            if options.ActiveSampleFullUpdate
                % Quick GP update                
                t = tic;
                if isempty(hypstruct); hypstruct = optimState.hypstruct; end
                [gp,hypstruct,Ns_gp,optimState] = ...
                    gptrain_vbmc(hypstruct,optimState,stats,options_update);    
                timer.gpTrain = timer.gpTrain + toc(t);
                
                % Quick variational optimization
                t = tic;
                
                % Decide number of fast optimizations
                Nfastopts = ceil(options_update.NSelboIncr * evaloption_vbmc(options_update.NSelbo,vp.K));
                if options.UpdateRandomAlpha
                    optimState.entropy_alpha = 1 - sqrt(rand());
                end
                vp = vpoptimize_vbmc(Nfastopts,1,vp,gp,[],optimState,options_update,0);
                optimState.vp_repo{end+1} = get_vptheta(vp);
                timer.variationalFit = timer.variationalFit + toc(t);
                
            else
                % Perform simple rank-1 update if no noise and first sample
                t = tic;
                update1 = (isempty(s2new) || optimState.nevals(idx_new) == 1) && ~options.NoiseShaping;
                if update1
                    gp = gplite_post(gp,xnew,ynew,[],[],[],s2new,1);
                    gp.t(end+1) = tnew;
                else
                    gp = gpreupdate(gp,optimState,options);                    
                end
                timer.gpTrain = timer.gpTrain + toc(t);
            end
        end
    end
    
    if options.ActiveSampleFullUpdate && Ns > 1
        optimState.RecomputeVarPost = RecomputeVarPost_old;
        optimState.entropy_alpha = entropy_alpha_old;
        optimState.hypstruct = hypstruct;        
    end
end

timer.activeSampling = timer.activeSampling + toc(time_active) ...
    - t_func - timer.gpTrain - timer.variationalFit;
timer.funEvals = timer.funEvals + t_func;

% Remove temporary fields (unnecessary here because GP is not returned)
% if isfield(gp,'sn2new'); gp = rmfield(gp,'sn2new'); end
% if isfield(gp,'X_rescaled'); gp = rmfield(gp,'X_rescaled'); end


end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [Xsearch,idx_cache] = getSearchPoints(NSsearch,optimState,vp,options)
%GETSEARCHPOINTS Get search points from starting cache or randomly generated.

% Take some points from starting cache, if not empty
x0 = optimState.Cache.X_orig;

if ~isempty(x0)
    cacheFrac = options.CacheFrac;  % Fraction of points from cache (if nonempty)
    Ncache = ceil(NSsearch*cacheFrac);            
    idx_cache = randperm(size(x0,1),min(Ncache,size(x0,1)));
    Xsearch = warpvars_vbmc(x0(idx_cache,:),'d',optimState.trinfo);        
else
    Xsearch = []; idx_cache = [];
end

% Randomly sample remaining points        
if size(Xsearch,1) < NSsearch
    Nrnd = NSsearch-size(Xsearch,1);
    
    Xrnd = [];
    Nsearchcache = round(options.SearchCacheFrac*Nrnd);
    if Nsearchcache > 0 % Take points from search cache
        Xrnd = [Xrnd; optimState.SearchCache(1:min(end,Nsearchcache),:)];
    end
    Nheavy = round(options.HeavyTailSearchFrac*Nrnd);
    if Nheavy > 0
        Xrnd = [Xrnd; vbmc_rnd(vp,Nheavy,0,1,3)];
    end
    Nmvn = round(options.MVNSearchFrac*Nrnd);
    if Nmvn > 0
        [mubar,Sigmabar] = vbmc_moments(vp,0);
        Xrnd = [Xrnd; mvnrnd(mubar,Sigmabar,Nmvn)];
    end
    Nhpd = round(options.HPDSearchFrac*Nrnd);
    if Nhpd > 0
        hpd_min = options.HPDFrac/8;
        hpd_max = options.HPDFrac;        
        hpdfracs = sort([rand(1,4)*(hpd_max-hpd_min) + hpd_min,hpd_min,hpd_max]);
        Nhpd_vec = diff(round(linspace(0,Nhpd,numel(hpdfracs)+1)));
        X = optimState.X(optimState.X_flag,:);
        y = optimState.y(optimState.X_flag);
        D = size(X,2);
        for ii = 1:numel(hpdfracs)
            if Nhpd_vec(ii) == 0; continue; end            
            X_hpd = gethpd_vbmc(X,y,hpdfracs(ii));
            if isempty(X_hpd)
                [~,idxmax] = max(y);
                mubar = X(idxmax,:);
                Sigmabar = cov(X);
            else
                mubar = mean(X_hpd,1);
                Sigmabar = cov(X_hpd,1);
            end
            if isscalar(Sigmabar); Sigmabar = Sigmabar*ones(D,D); end
            %[~,idxmax] = max(y);
            %x0 = optimState.X(idxmax,:);
            %[Sigmabar,mubar] = covcma(X,y,x0,[],hpdfracs(ii));
            Xrnd = [Xrnd; mvnrnd(mubar,Sigmabar,Nhpd_vec(ii))];
        end
    end
    Nvp = max(0,Nrnd-Nsearchcache-Nheavy-Nmvn-Nhpd);
    if Nvp > 0
        Xrnd = [Xrnd; vbmc_rnd(vp,Nvp,0,1)];
    end
    
    Xsearch = [Xsearch; Xrnd];
    idx_cache = [idx_cache(:); zeros(Nrnd,1)];
end

end
