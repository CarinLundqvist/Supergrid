using MAT, HDF5, JLD, DelimitedFiles, Statistics, Dates, TimeZones, Pkg.TOML

# If options[:datafolder] is set, then use that path. If not, use path listed in HOMEDIR/.GlobalEnergyGIS_config if available.
# Otherwise, fall back to Supergrid/inputdata where data for Europe8 is supplied.
function getdatafolder(options)
    if options[:datafolder] == ""
        configfile = joinpath(homedir(), ".GlobalEnergyGIS_config")
        if isfile(configfile)
            return joinpath(TOML.parsefile(configfile)["datafolder"], "output")
        else
            return abspath(dirname(@__FILE__), "..", "inputdata")
        end
    else
        return options[:datafolder]
    end
end

# eurasia21 regions for reference
# :NOR,:FRA,:GER,:UK,:MED,:BAL,:SPA,:CEN,:BUK,:TCC,:KZK,:CAS,:RU_C,:RU_SW,:RU_VL,:CH_N,:CH_NE,:CH_E,:CH_SC,:CH_SW,:CH_NW

function makesets(hourinfo, options)
    @unpack regionset, disableregions, inputdatasuffix = options
    inputdata = getdatafolder(options)
    distancevars = matread(joinpath(inputdata, "distances_$regionset.mat"))
    dataregions = Symbol.(vec(distancevars["regionlist"]))
    regionlist = setdiff(dataregions, disableregions)
    makesets(regionlist, dataregions, hourinfo, inputdatasuffix, options)
end

function makesets(REGION, dataregions, hourinfo, inputdatasuffix, options)
    @unpack datayear, regionset = options
    techdata = Dict(
        :name => [:pv,  :pvroof, :csp,     :wind, :offwind, :hydro,    :coal,    :gasGT,   :gasCCGT, :bioGT,   :bioCCGT, :nuclear, :battery],
        :type => [:vre, :vre,    :storage, :vre,  :vre,     :storage,  :thermal, :thermal, :thermal, :thermal, :thermal, :thermal, :storage],
        :fuel => [:_,   :_,      :_,       :_,    :_,       :_,        :coal,    :gas,     :gas,     :biogas,  :biogas,  :uranium, :_]
    )

    inputdata = getdatafolder(options)
    hydrovars = matread(joinpath(inputdata, "GISdata_hydro_$regionset.mat"))
    _, ncostclasses, nreservoirclasses = size(hydrovars["potentialcapac"])

    windvars = matread(joinpath(inputdata, "GISdata_wind$(datayear)_$regionset$inputdatasuffix.mat"))
    #solarvars = matread(joinpath(inputdata, "GISdata_solar$(datayear)_$regionset$inputdatasuffix.mat"))
    # Removed suffices to be able to use the same solar data for different wind-files
    solarvars = matread(joinpath(inputdata, "GISdata_solar$(datayear)_$regionset.mat"))
    nwindclasses = length(windvars["CFtime_windonshoreA"][1,1,:])
    noffwindclasses = length(windvars["CFtime_windoffshore"][1,1,:])
    npvclasses = length(solarvars["CFtime_pvplantA"][1,1,:])
    ncspclasses = length(solarvars["CFtime_cspplantA"][1,1,:])

    numtechs = length(techdata[:name])
    reservoirs = collect('a':'z')[1:nreservoirclasses]
    windclass = [Symbol("$letter$number") for letter in ["a", "b"] for number = 1:nwindclasses]
    offwindclass = [Symbol("$letter$number") for letter in ["a", "b"] for number = 1:noffwindclasses] #Remove class B?
    pvclass = [Symbol("$letter$number") for letter in ["a", "b"] for number = 1:npvclasses]
    cspclass = [Symbol("$letter$number") for letter in ["a", "b"] for number = 1:ncspclasses]
    hydroclass = [:x0;  [Symbol("$letter$number") for letter in reservoirs for number = 1:ncostclasses]]
    noclass = [:_]
    techtype = Dict(techdata[:name][i] => techdata[:type][i] for i=1:numtechs)
    techfuel = Dict(techdata[:name][i] => techdata[:fuel][i] for i=1:numtechs)

    TECH = techdata[:name]
    FUEL = [:_, :coal, :gas, :biogas, :uranium]
    CLASS = Dict(k =>
        k == :hydro ? hydroclass :
        k == :wind ? windclass :
        k == :offwind ? offwindclass :
        k == :pv ? pvclass :
        k == :pvroof ? pvclass :
        k == :csp ? cspclass :
        noclass for k in TECH)
    CLASS[:transmission] = noclass
    STORAGECLASS = Dict(k => [:_] for k in TECH)
    STORAGECLASS[:hydro] = [:x0;  Symbol.(reservoirs)]
    STORAGECLASS[:csp] = cspclass

    reservoirclass = Dict(r => [Symbol("$r$number") for number = 1:ncostclasses] for r in Symbol.(reservoirs))
    reservoirclass[:x0] = [:x0]
    reservoirclass[:_] = [:_]
    nvreclasses = max(length(windclass),length(offwindclass),length(pvclass),length(cspclass))
    vreclass = [Symbol("$letter$number") for letter in ["a", "b"] for number = 1:nvreclasses]
    for vc in vreclass
        reservoirclass[vc] = [vc]
    end

    HOUR = 1:(24*Dates.daysinyear(datayear)÷hourinfo.hours)

    return Sets(REGION, FUEL, TECH, CLASS, STORAGECLASS, HOUR, techtype, techfuel, reservoirclass, dataregions)
end

# resample hour dimension of array a (indicated by hourdim) using hourindexes in hourinfo structure,
# then reduce hours further by hours
function reducehours(a, hourdim, hourinfo)
    hours = hourinfo.hours
    aa = copy(selectdim(a, hourdim, hourinfo.hourindexes))
    out = copy(selectdim(aa, hourdim, 1:hours:size(aa,hourdim)))    # sample every nth hour
    if true     # true: averaging   false: sampling
        for i = 2:hours
            out += copy(selectdim(aa, hourdim, i:hours:size(aa,hourdim)))
        end
        out = out / hours
    end
    return out
end

# reduce regions from 10 (in Lina's input data) to 8 (in model)
# :MED = :IT + :GR,    :BAL (new) = :BAL (old) + :POL
function ten2eight(a)
    # REG10 = [:NOR, :IT, :FRA, :GER, :UK, :GR, :BAL, :POL, :SPA, :CEN]
    # REGION = [:NOR, :FRA, :GER, :UK, :MED, :BAL, :SPA, :CEN]
    out = a[[1,3,4,5,6,7,9,10],:]
    out[5,:] = a[2,:] + a[6,:]
    out[6,:] = a[7,:] + a[8,:]
    return out
end

CRF(r,T) = r / (1 - 1/(1+r)^T)

function makeparameters(sets, options, hourinfo)
    @unpack REGION, FUEL, TECH, CLASS, HOUR, dataregions = sets
    @unpack discountrate, datayear, regionset, solarwindarea, islandindexes,
            inputdatasuffix, sspscenario, sspyear, historical_allocation, allocation_of_wind, realistic_transmissioncapacity = options

    hoursperyear = 24 * Dates.daysinyear(datayear)
    hoursperperiod = Int(hourinfo.hoursperperiod)

    initialstoragelevel = 0.7       # make this tech dependent later
    minflow_existinghydro = 0.4
    cspsolarmultiple = 3.0          # peak capacity of collectors divided by turbine power
    cspthermalstoragehours = 12

    numregions = length(REGION)
    nhours = length(HOUR)
    nhydro = length(CLASS[:hydro])
    nclasses = max(length(CLASS[:wind]),length(CLASS[:offwind]),length(CLASS[:pv]),length(CLASS[:csp]))
    vreCLASS = [Symbol("$letter$number") for letter in ["a", "b"] for number = 1:Int(nclasses/2)]

    activeregions = [r in REGION for r in dataregions]
    demand = AxisArray(zeros(numregions, nhours), REGION, HOUR)     # GW

    inputdata = getdatafolder(options)

    # read synthetic demand data (in UTC)
    gisdemand = JLD.load(joinpath(inputdata,
        "SyntheticDemand_$(regionset)_$sspscenario-$(sspyear)_$datayear.jld"), "demand")
    for i = 1:numregions
        demand[i,:] = reducehours(gisdemand[:,i], 1, hourinfo) / 1000       # GW
    end

    hydrovars = matread(joinpath(inputdata, "GISdata_hydro_$regionset.mat"))
    hydrocapacity = AxisArray(zeros(numregions,nhydro), REGION, CLASS[:hydro])
    hydroeleccost = AxisArray(zeros(numregions,nhydro), REGION, CLASS[:hydro])
    monthlyinflow = AxisArray(zeros(numregions,nhydro,12), REGION, CLASS[:hydro], 1:12)
    cfhydroinflow = AxisArray(zeros(numregions,nhydro,nhours), REGION, CLASS[:hydro], HOUR)
    dischargetime = AxisArray(zeros(numregions,3,1+nhydro+nclasses), REGION, [:hydro,:battery,:csp], [CLASS[:hydro]; vreCLASS; :_])

    hydrocapacity[:,:x0] = typeof(hydrovars["existingcapac"]) == Float64 ? [hydrovars["existingcapac"]] : hydrovars["existingcapac"][activeregions]
    hydrocapacity[:,2:end] = reshape(hydrovars["potentialcapac"][activeregions,:,:], numregions, nhydro-1)
    hydrocapacity[isnan.(hydrocapacity)] = zeros(sum(isnan.(hydrocapacity)))

    # eleccost = capcost * crf / (CF * 8760)  =>   eleccost2/eleccost1 = crf2/crf1
    # 1$ = 0.9€ (average 2015-2017) 
    hydroeleccost[:,2:end] = reshape(hydrovars["potentialmeancost"][activeregions,:,:], numregions, nhydro-1)   # $/kWh with 10% discount rate
    hydroeleccost[:,:] = hydroeleccost[:,:] * CRF(discountrate,40)/CRF(0.1,40) * 0.9 * 1000     # €/MWh    (0.9 €/$)
    hydroeleccost[isnan.(hydroeleccost)] = fill(999, sum(isnan.(hydroeleccost)))

    monthlyinflow[:,:x0,:] = hydrovars["existinginflowcf"][activeregions,:]
    monthlyinflow[:,2:end,:] = reshape(hydrovars["potentialinflowcf"][activeregions,:,:,:], numregions, nhydro-1, 12)
    monthlyinflow[isnan.(monthlyinflow)] = zeros(sum(isnan.(monthlyinflow)))

    dischargetime[:,:hydro,:x0] .= 168*6    # assume average discharge time 6 weeks by default
    # if we have data on national storage capacity then use it 
    hydrostoragecapacity = Dict(:NOR => 121.43, :FRA => 3.59, :MED => 9.2, :SPA => 16.6, :CEN => 7.4)   # TWh
    for (reg, hydroenergy) in hydrostoragecapacity
        if reg in REGION
            dischargetime[reg,:hydro,:x0] = hydroenergy/hydrocapacity[reg,:x0] * 1000
        end
    end
    # these countries have mostly run-of-river hydro so discharge times are lower
    dischargetime[intersect([:GER,:UK,:BAL],REGION),:hydro,:x0] .= 300
    # use the GIS data for discharge time for future hydro 
    dischargetime[:,:hydro,2:end-1-nclasses] = reshape(hydrovars["potentialmeandischargetime"][activeregions,:,:], numregions, nhydro-1)

    dischargetime[:,:battery,:_] .= 1
    dischargetime[:,:csp,:] .= cspthermalstoragehours
    dischargetime[isnan.(dischargetime)] = fill(10000, sum(isnan.(dischargetime)))
    dischargetime[dischargetime .> 10000] = fill(10000, sum(dischargetime .> 10000))

    # monthly to hourly hydro inflow
    dayspermonth = Dates.daysinmonth.(Date.(datayear, 1:12))
    lasthour = 24 ÷ hoursperperiod * cumsum(dayspermonth)
    firsthour = [1; 1 .+ lasthour[1:end-1]]
    for m = 1:12
        for i = firsthour[m]:lasthour[m]
            cfhydroinflow[:,:,i] = monthlyinflow[:,:,m]
        end
    end
    cfhydroinflow[cfhydroinflow .< 0.01] = zeros(sum(cfhydroinflow .< 0.01))

    # read regional distances from Matlab file
    distancevars = matread(joinpath(inputdata, "distances_$regionset.mat"))

    if typeof(distancevars["distances"]) == Float64
        distances = fill(distancevars["distances"], 1, 1)
        connected = fill(distancevars["connected"], 1, 1)
        connectedoffshore = fill(distancevars["connectedoffshore"], 1, 1)
    else 
        distances = distancevars["distances"][activeregions,activeregions]
        connected = distancevars["connected"][activeregions,activeregions]
        connectedoffshore = distancevars["connectedoffshore"][activeregions,activeregions]
    end

    # add connection from south-central China to Germany
    indexGER = findfirst(REGION .== :GER)
    indexCHSC = findfirst(REGION .== :CH_SC)
    if indexGER != nothing && indexCHSC != nothing
        connected[indexGER,indexCHSC] = connected[indexCHSC,indexGER] = true
    end

    # from Bogdanov & Breyer (2016) "North-East Asian Super Grid..."
    transmissioncostdata = connected .* (180 .+ 0.4*distances) .+ connectedoffshore .* (180 .+ 0.47*distances)
    transmissionfixedcostdata = connected .* (1.8 .+ 0.008*distances) .+ connectedoffshore .* (1.8 .+ 0.00165*distances)
    transmissioninvestcost = AxisArray(transmissioncostdata, REGION, REGION)        # €/kW
    transmissionfixedcost = AxisArray(transmissionfixedcostdata, REGION, REGION)        # €/kW
    transmissionlossdata = (connected .| connectedoffshore) .* (0.014 .+ 0.016*distances/1000)
    transmissionlosses = AxisArray(transmissionlossdata, REGION, REGION)
    smalltransmissionpenalty = 0.1      # €/MWh elec

    islands = zeros(Bool, length(dataregions), length(dataregions))
    for ndx in islandindexes
        islands[ndx,ndx] .= true
    end
    transmissionislands = AxisArray(islands[activeregions,activeregions], REGION, REGION)

    # Efficiencies for storage technologies are round trip efficiencies.
    # CSP costs are adjusted for solar field size and storage capacity further below.
    techtable = [
        #               investcost  variablecost    fixedcost   lifetime    efficiency  rampingrate
        #               €/kW        €/MWh elec      €/kW/year   years                   share of capacity per hour
        :gasGT          500         1               10          30          0.35        1
        :gasCCGT        800         1               16          30          0.6         0.3
        :coal           1600        2               48          40          0.45        0.15
        :bioGT          500         1               10          30          0.35        1
        :bioCCGT        800         1               16          30          0.6         0.3
        :nuclear        5000        3.5             112         40          0.33        0.05
        :wind           825         0               33          25          1           1
        :offwind        1500        0               55          25          1           1
        :transmission   NaN         0               NaN         50          NaN         1
        :battery        116         0               1.5         15          0.85        1   # 1h discharge time, 150 €/kW = 150 €/kWh
        :pv             323         0               8           25          1           1
        :pvroof         423         0               5.8         25          1           1
        :csp            3746        2.9             56          30          1           1   # for solar multiple=3, storage=12 hours
        :hydro          300         0               25          80          1           1   # small artificial investcost so it doesn't overinvest in free capacity 
    ]
    techs = techtable[:,1]
    techdata = Float64.(techtable[:,2:end])
    baseinvestcost = AxisArray(techdata[:,1], techs)    # €/kW
    variablecost = AxisArray(techdata[:,2], techs)      # €/MWh elec
    fixedcost = AxisArray(techdata[:,3], techs)         # €/kW/year
    lifetime = AxisArray(techdata[:,4], techs)          # years
    efficiency = AxisArray(techdata[:,5], techs)
    rampingrate = AxisArray(techdata[:,6], techs)

    # fuel cost references:
    # 1. https://www.gov.uk/government/statistical-data-sets/prices-of-fuels-purchased-by-major-power-producers
    # 2. https://oilprice.com/Energy/Natural-Gas/European-Natural-Gas-Prices-Are-Set-To-Rise-Further.html
    # 3. https://www.bloomberg.com/news/articles/2018-09-03/coal-nears-100-in-europe-as-china-s-power-demand-draws-in-fuel
    # 4. https://www.frisch.uio.no/ressurser/LIBEMOD/pdf/phase_out_28mai2015_golombek_powerpoint.pdf
    # 5. http://www.world-nuclear.org/information-library/economic-aspects/economics-of-nuclear-power.aspx
    # 6. https://www.gasforclimate2050.eu/files/files/Ecofys_Gas_for_Climate_Report_Study_March18.pdf  (page 19, section 3.4, figure 7)
    # Sepulveda/Jenkins:  gas & biogas 21 €/MWh, uranium 3 €/MWh
    # 1: coal 11-12 €/MWh, gas 19-21 €/MWh,  2: gas 20-30 €/MWh,  3: coal 70-90 €/ton = (25 MJ/kg) = 2.8-3.6 €/GJ = 10-13 €/MWh
    # 4: gas 45*.5 = 22 €/MWh, coal 22.3*.4 = 9 €/MWh, bio 26.4*.4 = 11 €/MWh, nuclear 6.7*.35 = 2.3 €/MWh
    # 5: nuclear fuel pellets 0.39 USD/kWh = 3.2 €/MWh    (see also Stuff/Nuclear fuel costs.xlsx)
    # 6: biomethane anaerobic digestion 96 €/MWh (2015), 60 €/MWh (2050), thermal gasification 37 €/MWh (2050)
    
    fuelcost = AxisArray(Float64[0, 11, 22, 37, 2.6], [:_, :coal, :gas, :biogas, :uranium])     # €/MWh fuel

    crf = AxisArray(discountrate ./ (1 .- 1 ./(1+discountrate).^lifetime), techs)

    emissionsCO2 = AxisArray(zeros(length(FUEL)), FUEL)
    emissionsCO2[[:coal,:gas]] = [0.330, 0.202]     # kgCO2/kWh fuel (or ton/MWh or kton/GWh)

    windvars = matread(joinpath(inputdata, "GISdata_wind$(datayear)_$regionset$inputdatasuffix.mat"))
    #solarvars = matread(joinpath(inputdata, "GISdata_solar$(datayear)_$regionset$inputdatasuffix.mat"))
    # Removed suffices to be able to use the same solar data for different wind-files
    solarvars = matread(joinpath(inputdata, "GISdata_solar$(datayear)_$regionset.mat"))

    allclasses = union(vreCLASS, sets.CLASS[:hydro], [:_])
    classlimits = AxisArray(zeros(numregions,5,nclasses), REGION, [:wind, :offwind, :pv, :pvroof, :csp], vreCLASS)
    cf = AxisArray(ones(numregions,length(TECH),length(allclasses),nhours), REGION, TECH, allclasses, HOUR)
    solarcombinedarea = AxisArray(zeros(numregions,length(CLASS[:pv]),length(CLASS[:csp])), REGION, CLASS[:pv], CLASS[:csp])

    nwindclasses = Int(length(sets.CLASS[:wind])/2)
    noffwindclasses = Int(length(sets.CLASS[:offwind])/2)
    npvclasses = Int(length(sets.CLASS[:pv])/2)
    ncspclasses = Int(length(sets.CLASS[:csp])/2)
    bclasses = Int(nclasses/2)
    cf[:,:wind,1:nwindclasses,:] = permutedims(reducehours(windvars["CFtime_windonshoreA"][:,activeregions,:], 1, hourinfo), [2,3,1])
    cf[:,:offwind,1:noffwindclasses,:] = permutedims(reducehours(windvars["CFtime_windoffshore"][:,activeregions,:], 1, hourinfo), [2,3,1])
    cf[:,:pv,1:npvclasses,:] = permutedims(reducehours(solarvars["CFtime_pvplantA"][:,activeregions,:], 1, hourinfo), [2,3,1])
    cf[:,:pvroof,1:npvclasses,:] = permutedims(reducehours(solarvars["CFtime_pvrooftop"][:,activeregions,:], 1, hourinfo), [2,3,1])
    cf[:,:csp,1:ncspclasses,:] = permutedims(reducehours(solarvars["CFtime_cspplantA"][:,activeregions,:], 1, hourinfo), [2,3,1])
    cf[:,:wind,(bclasses+1):(bclasses+nwindclasses),:] = permutedims(reducehours(windvars["CFtime_windonshoreB"][:,activeregions,:], 1, hourinfo), [2,3,1])
    cf[:,:pv,(bclasses+1):(bclasses+npvclasses),:] = permutedims(reducehours(solarvars["CFtime_pvplantB"][:,activeregions,:], 1, hourinfo), [2,3,1])
    cf[:,:csp,(bclasses+1):(bclasses+ncspclasses),:] = permutedims(reducehours(solarvars["CFtime_cspplantB"][:,activeregions,:], 1, hourinfo), [2,3,1])
    cf[isnan.(cf)] = zeros(sum(isnan.(cf)))
    cf[cf .< 0.01] = zeros(sum(cf .< 0.01))     # set small values to 0 for better numerical stability

    classlimits[:,:wind,1:nwindclasses] = windvars["capacity_onshoreA"][activeregions,:] * solarwindarea
    classlimits[:,:offwind,1:noffwindclasses] = windvars["capacity_offshore"][activeregions,:] * (1 + 0.5*(solarwindarea - 1))    # only half because default offshore area is 33%
    classlimits[:,:pv,1:npvclasses] = solarvars["capacity_pvplantA"][activeregions,:] * solarwindarea
    classlimits[:,:pvroof,1:npvclasses] = solarvars["capacity_pvrooftop"][activeregions,:] * solarwindarea
    classlimits[:,:csp,1:ncspclasses] = solarvars["capacity_cspplantA"][activeregions,:] * solarwindarea
    classlimits[:,:wind,(bclasses+1):(bclasses+nwindclasses)] = windvars["capacity_onshoreB"][activeregions,:] * solarwindarea
    classlimits[:,:pv,(bclasses+1):(bclasses+npvclasses)] = solarvars["capacity_pvplantB"][activeregions,:] * solarwindarea
    classlimits[:,:csp,(bclasses+1):(bclasses+ncspclasses)] = solarvars["capacity_cspplantB"][activeregions,:] * solarwindarea

    #Assuming that it is pv first and then csp. This might be completely wrong
    #### OBS! MIGHT NEED TO CHANGE THIS TOO
    solarcombinedarea[:,1:npvclasses,1:ncspclasses] = solarvars["solar_overlap_areaA"][activeregions,:,:] * solarwindarea
    solarcombinedarea[:,(npvclasses+1):(2*npvclasses),(ncspclasses+1):(2*ncspclasses)] = solarvars["solar_overlap_areaB"][activeregions,:,:] * solarwindarea
    pv_density = solarvars["pv_density"]
    csp_density = solarvars["csp_density"]

    investcost = AxisArray(zeros(length(techs),length(allclasses)), techs, allclasses)  # €/kW
    for k in techs, c in CLASS[k]
        investcost[k,c] = baseinvestcost[k]
    end
    #for k in [:wind,:pv,:csp]
    #    investcost[k,6:10] .+= 200
    #end
    investcost[:wind,(bclasses+1):(bclasses+nwindclasses)] .+= 200
    investcost[:pv,(bclasses+1):(bclasses+npvclasses)] .+= 200
    investcost[:csp,(bclasses+1):(bclasses+ncspclasses)] .+= 200

    # CSP solar tower cost analysis (see CSP cost analysis.xlsx): 
    # Costs vary with the solar multiple (collector field size) and thermal storage capacity (in hours).
    # Assume a solar tower plant with solar multiple = 3 and storage = 12 hours costs 9200 USD/kW (2010).
    # Then assume solar field costs are 35% of total costs and storage about 10% of total costs (roughly inline with IRENA 2012, fig 4.4)
    # for this plant, and that costs for plants with other parameters vary linearly with solar multiple and storage size.
    # Finally convert to euro (1.15 USD/EUR) and assume a cost reduction of 25% to 2050. Resulting cost for a 3/12 solar tower: 6000 €/kW.
    investcost[:csp,:] = investcost[:csp,:] * (0.55 + 0.35*cspsolarmultiple/3 + 0.10*cspthermalstoragehours/12)

    cf[:,:csp,:,:] = cf[:,:csp,:,:] * cspsolarmultiple                          # OK if this surpasses 100%
    classlimits[:,:csp,:] = classlimits[:,:csp,:] / cspsolarmultiple            # GIS data calculated as peak solar power
    # The Capacity variable of the model should now be correct (turbine capacity, with a larger solar collector field)

    # # check demand/solar synchronization
    # plotly()
    # for r = 1:numregions
    #   tt1 = 8760÷2÷hoursperperiod     # test winter, spring, summer (÷12, ÷3, ÷2)
    #   tt = tt1:tt1+2*24÷hoursperperiod
    #   qq = [demand[r,tt] maximum(cf[r,:pv,1:5,tt],dims=1)']
    #   display(plot(qq./maximum(qq,dims=1), size=(1850,950)))
    # end

    if historical_allocation
        jakobsson_allocation = allocation_of_wind
        allocation = jakobsson_allocation .* 0.1
    else
        allocation = ones(10)
    end
    
    allocation = vcat(allocation,allocation)
    allocation_matrix = allocation' .* ones(numregions,length(CLASS[:wind]))
    windallocation = AxisArray(allocation_matrix, REGION, CLASS[:wind])

    transmissionlimits = getTransmissionLimits(regionset)

    return Params(cf, transmissionlosses, demand, hydrocapacity, cfhydroinflow, classlimits, transmissionislands,
        efficiency, rampingrate, dischargetime, initialstoragelevel, minflow_existinghydro, emissionsCO2, fuelcost,
        variablecost, smalltransmissionpenalty, investcost, crf, fixedcost, transmissioninvestcost, transmissionfixedcost,
        hydroeleccost, solarcombinedarea, pv_density, csp_density, cspsolarmultiple, windallocation, transmissionlimits)
end

# Run fix_timezone_error() if an error like this is produced (the build step should take care if this for most people):
# (I'm not even sure if this helps...)
#
# julia> r, annualelec, capac, tcapac, chart = runmodel(regionset=:europe8, carboncap=0.1, hours=3);
#
# Reading input data...
#   1.257888 seconds (1.77 M allocations: 92.844 MiB, 2.44% gc time)
# ERROR: UnhandledTimeError: TimeZone Europe/Oslo does not handle dates on or after 2038-03-28T01:00:00 UTC
fix_timezone_error() = TimeZones.TZData.compile(max_year=2200)

function getTransmissionLimits(regionset)
    if regionset == "Transmission_Australia"
        REGION = [:AUS_NE, :AUS_E, :AUS_SE, :AUS_S, :AUS_W, :AUS_N]
        transmissionmatrix =   [0  1.2   0   0   0   0;
                                1.2  0   0.9  0   0   0;
                                0  0.9   0  0.9  0   0;
                                0   0   0.9  0   0   0;
                                0   0    0   0   0   0;
                                0   0    0   0   0   0]
    elseif regionset == "Transmission_USA"
        # NERC had this map of Tranfer capabilities: https://www.nerc.com/pa/RAPA/Documents/ITCS_CTC_Map.pdf
        REGION = [Symbol("West"), Symbol("Central West"), Symbol("South"), Symbol("Middle"), Symbol("Southeast"), Symbol("East"), Symbol("Northest")]
        transmissionmatrix =   [0   30   0    0   0   0   0;
                                30   0  0.4  0.7  0   0   0;
                                0  0.4   0    5   10  5   0;
                                0  0.7   5    0   0   15  0;
                                0   0    10   0   0   26  0;
                                0   0    5    15  26  0   5;
                                0   0    0    0   0   5   0]
    elseif regionset == "Transmission_Europe"
        REGION = [:SWE, :NOR, :DEN, :FIN, :NL, :BL, :LX, :GER, :FRA, :UK, :IR, :ITA, :POL, :EST, :LAT, :LIT, :SPA, :POR, :AUS, :SWI, :CZR, :SLO, :HUN]
        transmissionmatrix = zeros(length(REGION),length(REGION))
        # Using 2025 numbers from Ember: https://ember-energy.org/latest-insights/breaking-borders-europe-electricity-interconnectors/
        # Transmissions to and from Sweden
        transmissionmatrix[1,2] = transmissionmatrix[2,1] = 3.7 #Sweden
        transmissionmatrix[1,3] = transmissionmatrix[3,1] = 2.5 #Denmark
        transmissionmatrix[1,4] = transmissionmatrix[4,1] = 2.4 #Finland
        transmissionmatrix[1,8] = transmissionmatrix[8,1] = 0.6 #Germany
        transmissionmatrix[1,13] = transmissionmatrix[13,1] = 0.6   #Poland
        transmissionmatrix[1,16] = transmissionmatrix[16,1] = 0.7   #Lithuania
        # Transmissions to and from Norway
        transmissionmatrix[2,3] = transmissionmatrix[3,2] = 1.6 #Denmark
        transmissionmatrix[2,5] = transmissionmatrix[5,2] = 0.7 #Netherlands
        transmissionmatrix[2,8] = transmissionmatrix[8,2] = 1.4 #Germany
        transmissionmatrix[2,10] = transmissionmatrix[10,2] = 1.4   #UK
        # Transmissions to and from Denmark
        transmissionmatrix[3,5] = transmissionmatrix[5,3] = 0.7 #Netherlands
        transmissionmatrix[3,8] = transmissionmatrix[8,3] = 4.7 #Germany
        transmissionmatrix[3,10] = transmissionmatrix[10,3] = 1.4 #UK
        # Transmissions to and from Finland
        transmissionmatrix[4,14] = transmissionmatrix[14,4] = 1 #Estonia
        # Transmisisons to and from Netherlands
        transmissionmatrix[5,6] = transmissionmatrix[6,5] = 3.4 #Belgium
        transmissionmatrix[5,8] = transmissionmatrix[8,5] = 5 #Germany
        transmissionmatrix[5,10] = transmissionmatrix[10,5] = 1 #UK
        # Transmisisons to and from Belgium
        transmissionmatrix[6,7] = transmissionmatrix[7,6] = 0.7 #Luxembourg
        transmissionmatrix[6,8] = transmissionmatrix[8,6] = 1 #Germany
        transmissionmatrix[6,9] = transmissionmatrix[9,6] = 4.3 #France
        transmissionmatrix[6,10] = transmissionmatrix[10,6] = 1 #UK
        # Transmissions to and from Luxembourg
        transmissionmatrix[7,8] = transmissionmatrix[8,7] = 2.3 #Germany
        transmissionmatrix[7,9] = transmissionmatrix[9,7] = 0.4 #France
        # Transmissions to and from Germany
        transmissionmatrix[8,21] = transmissionmatrix[21,8] = 1.6 #Czech republic
        transmissionmatrix[8,20] = transmissionmatrix[20,8] = 4.2 #Switzerland
        transmissionmatrix[8,19] = transmissionmatrix[19,8] = 5.4 #Austria
        transmissionmatrix[8,13] = transmissionmatrix[13,8] = 3   #Poland
        transmissionmatrix[8,9] = transmissionmatrix[9,8] = 3.3   #France
        # Transmissions to and from France
        transmissionmatrix[9,17] = transmissionmatrix[17,9] = 5   #Spain
        transmissionmatrix[9,10] = transmissionmatrix[10,9] = 4   #UK
        transmissionmatrix[9,20] = transmissionmatrix[20,9] = 3.7   #Switzerland
        transmissionmatrix[9,12] = transmissionmatrix[12,9] = 4.1   #Italy
        # Transmissions to and from UK
        transmissionmatrix[10,11] = transmissionmatrix[11,10] = 1.8   #Ireland
        # Transmissions to and from Ireland
            # See UK
        # Transmissions to and from Italy
        transmissionmatrix[12,20] = transmissionmatrix[20,12] = 3.8   #Switzerland
        transmissionmatrix[12,19] = transmissionmatrix[19,12] = 0.8   #Austria
            # Excluded transmissions: Montenegro, Greece, Malta, Slovenia
        # Transmissions to and from Poland
        transmissionmatrix[13,21] = transmissionmatrix[21,13] = 1.4   #Czech republic
        transmissionmatrix[13,22] = transmissionmatrix[22,13] = 2   #Slovakia
        transmissionmatrix[13,16] = transmissionmatrix[16,13] = 0.5   #Lithuania
        # Transmissions to and from Estonia
        transmissionmatrix[14,22] = transmissionmatrix[22,14] = 1.1   #Latvia
        # Transmissions to and from Latvia
        transmissionmatrix[15,16] = transmissionmatrix[16,15] = 1   #Lithuania
        # Transmissions to and from Lithuania
            # See Latvia, Poland, Sweden
        # Transmissions to and from Spain
        transmissionmatrix[17,18] = transmissionmatrix[18,17] = 4.2   #Portugal
        # Transmissions to and from Portugal
            # See Spain
        # Transmissions to and from Austria
        transmissionmatrix[19,20] = transmissionmatrix[20,19] = 1.2   #Switzerland
        transmissionmatrix[19,21] = transmissionmatrix[21,19] = 0.9   #Czech republic
        transmissionmatrix[19,23] = transmissionmatrix[23,19] = 0.8   #Hungary
            # Excluded transmissions: Slovenia
        # Transmissions to and from Switzerland
            # See France, Germany, Austria and Italy
        # Transmissions to and from the Czech republic
        transmissionmatrix[21,22] = transmissionmatrix[22,21] = 1.8   #Slovakia
        # Transmissions to and from the Slovakia
        transmissionmatrix[22,23] = transmissionmatrix[23,22] = 2.6   #Hungary
            # Excluded transmissions: Ukraine
        # Transmissions to and from Hungary
            # Excluded transmissions: Slovenia, Croatia, Serbia, Romania, Ukraine
    elseif regionset == "Transmission_China"
        REGION = [:CH_N, :CH_NE, :CH_E, :CH_SC, :CH_SW, :CH_NW]
        transmissionmatrix = [  0   5   77.3   5    0   3.6;
                                5   0    0   2.6    0    0;
                              77.3  0    0    15  45.6  43.5;
                                5  2.6   15    0   50   33.1;
                                0   0   45.6  50    0   3.6;
                               3.6  0   43.5 33.1  3.6   0]
    else
        REGION = [:NoRegion]
        transmissionmatrix = zeros(length(REGION),length(REGION))
    end
    transmissionlimits = AxisArray(transmissionmatrix, REGION, REGION)
    return transmissionlimits
end
