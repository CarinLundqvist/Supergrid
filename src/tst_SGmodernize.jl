# File for running Supergrid
include("Supergrid.jl")
import .Supergrid

r, annualelec, capac, tcapac, chart = Supergrid.runmodel(regionset="Sweden",
                                                        inputdatasuffix = "TEST1",
                                                        sspscenario = "ssp2-34",
                                                        solver = :gurobi,
                                                        datayear = 2018,
                                                        showsolverlog = false,
                                                        resultsfile = "C:/Users/lucarin/Documents/Thesis paper PhD/results_SWE.jld2")
list = Supergrid.listresults(resultsfile="results_SWE.jld2")
r = Supergrid.loadresults(list[1],resultsfile="results_SWE.jld2")
elec, capac, tcapac, chart = Supergrid.analyzeresults(r)
println(elec)





