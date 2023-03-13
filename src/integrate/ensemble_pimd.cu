/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, Mikko Ervasti, and Ari Harju
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/

/*----------------------------------------------------------------------------80
The global path-integral Langevin equation (PILE) thermostat:
[1] Ceriotti et al., J. Chem. Phys. 133, 124104 (2010).
------------------------------------------------------------------------------*/

#include "ensemble_pimd.cuh"
#include "langevin_utilities.cuh"
#include "utilities/common.cuh"
#include <cstdlib>

Ensemble_PIMD::Ensemble_PIMD(
  int number_of_atoms_input,
  int number_of_beads_input,
  double temperature_input,
  double temperature_coupling_input,
  double temperature_coupling_beads_input)
{
  number_of_atoms = number_of_atoms_input;
  number_of_beads = number_of_beads_input;
  temperature = temperature_input;
  temperature_coupling = temperature_coupling_input;
  temperature_coupling_beads = temperature_coupling_beads_input;
  c1 = exp(-0.5 / temperature_coupling_beads);
  c2 = sqrt((1 - c1 * c1) * K_B * temperature);

  position.resize(number_of_beads);
  velocity.resize(number_of_beads);
  force.resize(number_of_beads);
  for (int b = 0; b < number_of_beads; ++b) {
    position[b].resize(number_of_atoms * 3);
    velocity[b].resize(number_of_atoms * 3);
    force[b].resize(number_of_atoms * 3);
    beads.position[b] = position[b].data();
    beads.velocity[b] = velocity[b].data();
    beads.force[b] = force[b].data();
  }

  // TODO: initializing position and velocity data for the beads

  transformation_matrix.resize(number_of_beads * number_of_beads);
  std::vector<double> transformation_matrix_cpu(number_of_beads * number_of_beads);
  double sqrt_factor_1 = sqrt(1.0 / number_of_beads);
  double sqrt_factor_2 = sqrt(2.0 / number_of_beads);
  for (int j = 1; j <= number_of_beads; ++j) {
    float sign_factor = (j % 2 == 0) ? 1.0f : -1.0f;
    for (int k = 0; k < number_of_beads; ++k) {
      int jk = (j - 1) * number_of_beads + k;
      double pi_factor = 2.0 * PI * j * k / number_of_beads;
      if (k == 0) {
        transformation_matrix_cpu[jk] = sqrt_factor_1;
      } else if (k < number_of_beads / 2) {
        transformation_matrix_cpu[jk] = sqrt_factor_2 * cos(pi_factor);
      } else if (k == number_of_beads / 2) {
        transformation_matrix_cpu[jk] = sqrt_factor_1 * sign_factor;
      } else {
        transformation_matrix_cpu[jk] = sqrt_factor_2 * sin(pi_factor);
      }
    }
  }
  transformation_matrix.copy_from_host(transformation_matrix_cpu.data());

  curand_states.resize(number_of_atoms);
  int grid_size = (number_of_atoms - 1) / 128 + 1;
  initialize_curand_states<<<grid_size, 128>>>(curand_states.data(), number_of_atoms, rand());
  CUDA_CHECK_KERNEL
}

Ensemble_PIMD::~Ensemble_PIMD(void)
{
  // nothing
}

// wrapper of the global Langevin thermostatting kernels
void Ensemble_PIMD::integrate_nvt_lan_half(
  const GPU_Vector<double>& mass, GPU_Vector<double>& velocity_per_atom)
{
  const int number_of_atoms = mass.size();

  gpu_langevin<<<(number_of_atoms - 1) / 128 + 1, 128>>>(
    curand_states.data(), number_of_atoms, c1, c2, mass.data(), velocity_per_atom.data(),
    velocity_per_atom.data() + number_of_atoms, velocity_per_atom.data() + 2 * number_of_atoms);
  CUDA_CHECK_KERNEL

  gpu_find_momentum<<<4, 1024>>>(
    number_of_atoms, mass.data(), velocity_per_atom.data(),
    velocity_per_atom.data() + number_of_atoms, velocity_per_atom.data() + 2 * number_of_atoms);
  CUDA_CHECK_KERNEL

  gpu_correct_momentum<<<(number_of_atoms - 1) / 128 + 1, 128>>>(
    number_of_atoms, velocity_per_atom.data(), velocity_per_atom.data() + number_of_atoms,
    velocity_per_atom.data() + 2 * number_of_atoms);
  CUDA_CHECK_KERNEL
}

void Ensemble_PIMD::compute1(
  const double time_step,
  const std::vector<Group>& group,
  const GPU_Vector<double>& mass,
  const GPU_Vector<double>& potential_per_atom,
  const GPU_Vector<double>& force_per_atom,
  const GPU_Vector<double>& virial_per_atom,
  Box& box,
  GPU_Vector<double>& position_per_atom,
  GPU_Vector<double>& velocity_per_atom,
  GPU_Vector<double>& thermo)
{
  integrate_nvt_lan_half(mass, velocity_per_atom);
  velocity_verlet(
    true, time_step, group, mass, force_per_atom, position_per_atom, velocity_per_atom);
}

void Ensemble_PIMD::compute2(
  const double time_step,
  const std::vector<Group>& group,
  const GPU_Vector<double>& mass,
  const GPU_Vector<double>& potential_per_atom,
  const GPU_Vector<double>& force_per_atom,
  const GPU_Vector<double>& virial_per_atom,
  Box& box,
  GPU_Vector<double>& position_per_atom,
  GPU_Vector<double>& velocity_per_atom,
  GPU_Vector<double>& thermo)
{
  velocity_verlet(
    false, time_step, group, mass, force_per_atom, position_per_atom, velocity_per_atom);
  integrate_nvt_lan_half(mass, velocity_per_atom);
  find_thermo(
    true, box.get_volume(), group, mass, potential_per_atom, velocity_per_atom, virial_per_atom,
    thermo);
}
