function [cost, f_cal] = find_cost(population)
N_pop = size(population, 1);
cost = zeros(N_pop, 1);
load r;
load f_ref;
N_atom=size(r,1);
L=[9.483921 9.483921 9.483921];
for n_pop = 1 : N_pop
    para=population(n_pop,:);
    [NN,NL]=find_neighbor(N_atom,L,4,r);
    [energy,f_cal]=find_force_train(N_atom,NN,NL,L,4,r,para);
    cost(n_pop) = sqrt(mean(mean((f_cal - f_ref).^2))) ...
        + 1.0e-5 * 0.5 * sum(para.^2) + 0.0e-5 * sum(abs(para));
end
