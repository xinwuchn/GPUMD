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
The driver class dealing with measurement.
------------------------------------------------------------------------------*/

#include "dump_xyz.cuh"
#include "measure.cuh"
#include "utilities/error.cuh"
#include "utilities/read_file.cuh"
#ifdef USE_NETCDF
#include "dump_netcdf.cuh"
#endif
#define NUM_OF_HEAT_COMPONENTS 5

void Measure::initialize(
  char* input_dir,
  const int number_of_steps,
  const double time_step,
  const std::vector<Group>& group,
  const std::vector<int>& cpu_type_size,
  const GPU_Vector<double>& mass)
{
  const int number_of_atoms = mass.size();
  if (dump_pos) {
    dump_pos->initialize(input_dir, number_of_atoms);
  }
  vac.preprocess(time_step, group, mass);
  hac.preprocess(number_of_steps);
  shc.preprocess(number_of_atoms, group);
  compute.preprocess(number_of_atoms, input_dir, group);
  hnemd.preprocess();
  modal_analysis.preprocess(input_dir, cpu_type_size, mass);
  dump_velocity.preprocess(input_dir);
  dump_restart.preprocess(input_dir);
  dump_thermo.preprocess(input_dir);
  dump_force.preprocess(input_dir, number_of_atoms);
}

void Measure::finalize(
  char* input_dir,
  const int number_of_steps,
  const double time_step,
  const double temperature,
  const double volume)
{
  if (dump_pos) {
    dump_pos->finalize();
  }
  dump_velocity.postprocess();
  dump_restart.postprocess();
  dump_thermo.postprocess();
  dump_force.postprocess();
  vac.postprocess(input_dir);
  hac.postprocess(number_of_steps, input_dir, temperature, time_step, volume);
  shc.postprocess(input_dir);
  compute.postprocess();
  hnemd.postprocess();
  modal_analysis.postprocess();

  // reset the defaults
  compute.compute_temperature = 0;
  compute.compute_potential = 0;
  compute.compute_force = 0;
  compute.compute_virial = 0;
  compute.compute_jp = 0;
  compute.compute_jk = 0;
  shc.compute = 0;
  modal_analysis.compute = 0;
  modal_analysis.method = NO_METHOD;
  hnemd.compute = 0;

  if (dump_pos) {
    delete dump_pos;
  }
  dump_pos = NULL;
}

void Measure::process(
  char* input_dir,
  const int number_of_steps,
  int step,
  const int fixed_group,
  const double global_time,
  const double temperature,
  const double energy_transferred[],
  const std::vector<int>& cpu_type,
  Box& box,
  const Neighbor& neighbor,
  std::vector<Group>& group,
  GPU_Vector<double>& thermo,
  const GPU_Vector<double>& mass,
  const std::vector<double>& cpu_mass,
  GPU_Vector<double>& position_per_atom,
  std::vector<double>& cpu_position_per_atom,
  GPU_Vector<double>& velocity_per_atom,
  std::vector<double>& cpu_velocity_per_atom,
  GPU_Vector<double>& potential_per_atom,
  GPU_Vector<double>& force_per_atom,
  GPU_Vector<double>& virial_per_atom,
  GPU_Vector<double>& heat_per_atom)
{
  const int number_of_atoms = cpu_type.size();

  dump_thermo.process(
    step, number_of_atoms, (fixed_group < 0) ? 0 : group[0].cpu_size[fixed_group], box, thermo);

  dump_velocity.process(step, velocity_per_atom, cpu_velocity_per_atom);

  dump_restart.process(
    step, neighbor, box, group, cpu_type, cpu_mass, position_per_atom, velocity_per_atom,
    cpu_position_per_atom, cpu_velocity_per_atom);

  dump_force.process(step, force_per_atom);

  compute.process(
    step, energy_transferred, group, mass, potential_per_atom, force_per_atom, velocity_per_atom,
    virial_per_atom);

  vac.process(step, group, velocity_per_atom);

  hac.process(number_of_steps, step, input_dir, velocity_per_atom, virial_per_atom, heat_per_atom);

  shc.process(step, group, velocity_per_atom, virial_per_atom);

  hnemd.process(
    step, input_dir, temperature, box.get_volume(), velocity_per_atom, virial_per_atom,
    heat_per_atom);

  modal_analysis.process(
    step, temperature, box.get_volume(), hnemd.fe, velocity_per_atom, virial_per_atom);

  if (dump_pos) {
    dump_pos->dump(step, global_time, box, cpu_type, position_per_atom, cpu_position_per_atom);
  }
}

void Measure::parse_dump_position(char** param, int num_param)
{
  int interval;

  if (num_param < 2) {
    PRINT_INPUT_ERROR("dump_position should have at least 1 parameter.");
  }
  if (num_param > 6) {
    PRINT_INPUT_ERROR("dump_position has too many parameters.");
  }

  // sample interval
  if (!is_valid_int(param[1], &interval)) {
    PRINT_INPUT_ERROR("position dump interval should be an integer.");
  }

  int format = 0;    // default xyz
  int precision = 0; // default normal (unlesss netCDF -> 64 bit)
  // Process optional arguments
  for (int k = 2; k < num_param; k++) {
    // format check
    if (strcmp(param[k], "format") == 0) {
      // check if there are enough inputs
      if (k + 2 > num_param) {
        PRINT_INPUT_ERROR("Not enough arguments for optional "
                          " 'format' dump_position command.\n");
      }
      if ((strcmp(param[k + 1], "xyz") != 0) && (strcmp(param[k + 1], "netcdf") != 0)) {
        PRINT_INPUT_ERROR("Invalid format for dump_position command.\n");
      } else if (strcmp(param[k + 1], "netcdf") == 0) {
        format = 1;
        k++;
      }
    }
    // precision check
    else if (strcmp(param[k], "precision") == 0) {
      // check for enough inputs
      if (k + 2 > num_param) {
        PRINT_INPUT_ERROR("Not enough arguments for optional "
                          " 'precision' dump_position command.\n");
      }
      if ((strcmp(param[k + 1], "single") != 0) && (strcmp(param[k + 1], "double") != 0)) {
        PRINT_INPUT_ERROR("Invalid precision for dump_position command.\n");
      } else {
        if (strcmp(param[k + 1], "single") == 0) {
          precision = 1;
        } else if (strcmp(param[k + 1], "double") == 0) {
          precision = 2;
        }
        k++;
      }
    }
  }

  if (format == 1) // netcdf output
  {
#ifdef USE_NETCDF
    DUMP_NETCDF* dump_netcdf = new DUMP_NETCDF();
    dump_pos = dump_netcdf;
    if (!precision)
      precision = 2; // double precision default
#else
    PRINT_INPUT_ERROR("USE_NETCDF flag is not set. NetCDF output not available.\n");
#endif
  } else // xyz default output
  {
    DUMP_XYZ* dump_xyz = new DUMP_XYZ();
    dump_pos = dump_xyz;
  }
  dump_pos->interval = interval;
  dump_pos->precision = precision;

  if (precision == 1 && format) {
    printf("Note: Single precision netCDF output does not follow AMBER conventions.\n"
           "      However, it will still work for many readers.\n");
  }

  printf("Dump position every %d steps.\n", dump_pos->interval);
}

void Measure::parse_compute_gkma(char** param, int num_param, const int number_of_types)
{
  modal_analysis.compute = 1;
  if (modal_analysis.method == GKMA_METHOD) { // TODO add warning macro
    printf("*******************************************************"
           "WARNING: GKMA method already defined for this run.\n"
           "         Parameters will be overwritten\n"
           "*******************************************************");
  } else if (modal_analysis.method == HNEMA_METHOD) {
    printf("*******************************************************"
           "WARNING: HNEMA method already defined for this run.\n"
           "         GKMA will now run instead.\n"
           "*******************************************************");
  }
  modal_analysis.method = GKMA_METHOD;

  printf("Compute modal heat current using GKMA method.\n");

  /*
   * There is a hidden feature that allows for specification of atom
   * types to included (must be contiguously defined like potentials)
   * -- Works for types only, not groups --
   */

  if (num_param != 6 && num_param != 9) {
    PRINT_INPUT_ERROR("compute_gkma should have 5 parameters.\n");
  }
  if (
    !is_valid_int(param[1], &modal_analysis.sample_interval) ||
    !is_valid_int(param[2], &modal_analysis.first_mode) ||
    !is_valid_int(param[3], &modal_analysis.last_mode)) {
    PRINT_INPUT_ERROR("A parameter for GKMA should be an integer.\n");
  }

  if (strcmp(param[4], "bin_size") == 0) {
    modal_analysis.f_flag = 0;
    if (!is_valid_int(param[5], &modal_analysis.bin_size)) {
      PRINT_INPUT_ERROR("GKMA bin_size must be an integer.\n");
    }
  } else if (strcmp(param[4], "f_bin_size") == 0) {
    modal_analysis.f_flag = 1;
    if (!is_valid_real(param[5], &modal_analysis.f_bin_size)) {
      PRINT_INPUT_ERROR("GKMA f_bin_size must be a real number.\n");
    }
  } else {
    PRINT_INPUT_ERROR("Invalid binning keyword for compute_gkma.\n");
  }

  MODAL_ANALYSIS* g = &modal_analysis;
  // Parameter checking
  if (g->sample_interval < 1 || g->first_mode < 1 || g->last_mode < 1)
    PRINT_INPUT_ERROR("compute_gkma parameters must be positive integers.\n");
  if (g->first_mode > g->last_mode)
    PRINT_INPUT_ERROR("first_mode <= last_mode required.\n");

  printf(
    "    sample_interval is %d.\n"
    "    first_mode is %d.\n"
    "    last_mode is %d.\n",
    g->sample_interval, g->first_mode, g->last_mode);

  if (g->f_flag) {
    if (g->f_bin_size <= 0.0) {
      PRINT_INPUT_ERROR("bin_size must be greater than zero.\n");
    }
    printf(
      "    Bin by frequency.\n"
      "    f_bin_size is %f THz.\n",
      g->f_bin_size);
  } else {
    if (g->bin_size < 1) {
      PRINT_INPUT_ERROR("compute_gkma parameters must be positive integers.\n");
    }
    int num_modes = g->last_mode - g->first_mode + 1;
    if (num_modes % g->bin_size != 0)
      PRINT_INPUT_ERROR("number of modes must be divisible by bin_size.\n");
    printf(
      "    Bin by modes.\n"
      "    bin_size is %d THz.\n",
      g->bin_size);
  }

  // Hidden feature implementation
  if (num_param == 9) {
    if (strcmp(param[6], "atom_range") == 0) {
      if (
        !is_valid_int(param[7], &modal_analysis.atom_begin) ||
        !is_valid_int(param[8], &modal_analysis.atom_end)) {
        PRINT_INPUT_ERROR("GKMA atom_begin & atom_end must be integers.\n");
      }
      if (modal_analysis.atom_begin > modal_analysis.atom_end) {
        PRINT_INPUT_ERROR("atom_begin must be less than atom_end.\n");
      }
      if (modal_analysis.atom_begin < 0) {
        PRINT_INPUT_ERROR("atom_begin must be greater than 0.\n");
      }
      if (modal_analysis.atom_end >= number_of_types) {
        PRINT_INPUT_ERROR("atom_end must be greater than 0.\n");
      }
    } else {
      PRINT_INPUT_ERROR("Invalid GKMA keyword.\n");
    }
    printf(
      "    Use select atom range.\n"
      "    Atom types %d to %d.\n",
      modal_analysis.atom_begin, modal_analysis.atom_end);
  } else // default behavior
  {
    modal_analysis.atom_begin = 0;
    modal_analysis.atom_end = number_of_types - 1;
  }
}

void Measure::parse_compute_hnema(char** param, int num_param, const int number_of_types)
{
  modal_analysis.compute = 1;
  if (modal_analysis.method == HNEMA_METHOD) {
    printf("*******************************************************\n"
           "WARNING: HNEMA method already defined for this run.\n"
           "         Parameters will be overwritten\n"
           "*******************************************************\n");
  } else if (modal_analysis.method == GKMA_METHOD) {
    printf("*******************************************************\n"
           "WARNING: GKMA method already defined for this run.\n"
           "         HNEMA will now run instead.\n"
           "*******************************************************\n");
  }
  modal_analysis.method = HNEMA_METHOD;

  printf("Compute modal thermal conductivity using HNEMA method.\n");

  /*
   * There is a hidden feature that allows for specification of atom
   * types to included (must be contiguously defined like potentials)
   * -- Works for types only, not groups --
   */

  if (num_param != 10 && num_param != 13) {
    PRINT_INPUT_ERROR("compute_hnema should have 9 parameters.\n");
  }
  if (
    !is_valid_int(param[1], &modal_analysis.sample_interval) ||
    !is_valid_int(param[2], &modal_analysis.output_interval) ||
    !is_valid_int(param[6], &modal_analysis.first_mode) ||
    !is_valid_int(param[7], &modal_analysis.last_mode)) {
    PRINT_INPUT_ERROR("A parameter for HNEMA should be an integer.\n");
  }

  // HNEMD driving force parameters -> Use HNEMD object
  if (!is_valid_real(param[3], &hnemd.fe_x)) {
    PRINT_INPUT_ERROR("fe_x for HNEMD should be a real number.\n");
  }
  printf("    fe_x = %g /A\n", hnemd.fe_x);
  if (!is_valid_real(param[4], &hnemd.fe_y)) {
    PRINT_INPUT_ERROR("fe_y for HNEMD should be a real number.\n");
  }
  printf("    fe_y = %g /A\n", hnemd.fe_y);
  if (!is_valid_real(param[5], &hnemd.fe_z)) {
    PRINT_INPUT_ERROR("fe_z for HNEMD should be a real number.\n");
  }
  printf("    fe_z = %g /A\n", hnemd.fe_z);
  // magnitude of the vector
  hnemd.fe = hnemd.fe_x * hnemd.fe_x;
  hnemd.fe += hnemd.fe_y * hnemd.fe_y;
  hnemd.fe += hnemd.fe_z * hnemd.fe_z;
  hnemd.fe = sqrt(hnemd.fe);

  if (strcmp(param[8], "bin_size") == 0) {
    modal_analysis.f_flag = 0;
    if (!is_valid_int(param[9], &modal_analysis.bin_size)) {
      PRINT_INPUT_ERROR("HNEMA bin_size must be an integer.\n");
    }
  } else if (strcmp(param[8], "f_bin_size") == 0) {
    modal_analysis.f_flag = 1;
    if (!is_valid_real(param[9], &modal_analysis.f_bin_size)) {
      PRINT_INPUT_ERROR("HNEMA f_bin_size must be a real number.\n");
    }
  } else {
    PRINT_INPUT_ERROR("Invalid binning keyword for compute_hnema.\n");
  }

  MODAL_ANALYSIS* h = &modal_analysis;
  // Parameter checking
  if (h->sample_interval < 1 || h->output_interval < 1 || h->first_mode < 1 || h->last_mode < 1)
    PRINT_INPUT_ERROR("compute_hnema parameters must be positive integers.\n");
  if (h->first_mode > h->last_mode)
    PRINT_INPUT_ERROR("first_mode <= last_mode required.\n");
  if (h->output_interval % h->sample_interval != 0)
    PRINT_INPUT_ERROR("sample_interval must divide output_interval an integer\n"
                      " number of times.\n");

  printf(
    "    sample_interval is %d.\n"
    "    output_interval is %d.\n"
    "    first_mode is %d.\n"
    "    last_mode is %d.\n",
    h->sample_interval, h->output_interval, h->first_mode, h->last_mode);

  if (h->f_flag) {
    if (h->f_bin_size <= 0.0) {
      PRINT_INPUT_ERROR("bin_size must be greater than zero.\n");
    }
    printf(
      "    Bin by frequency.\n"
      "    f_bin_size is %f THz.\n",
      h->f_bin_size);
  } else {
    if (h->bin_size < 1) {
      PRINT_INPUT_ERROR("compute_hnema parameters must be positive integers.\n");
    }
    printf(
      "    Bin by modes.\n"
      "    bin_size is %d modes.\n",
      h->bin_size);
  }

  // Hidden feature implementation
  if (num_param == 13) {
    if (strcmp(param[10], "atom_range") == 0) {
      if (
        !is_valid_int(param[11], &modal_analysis.atom_begin) ||
        !is_valid_int(param[12], &modal_analysis.atom_end)) {
        PRINT_INPUT_ERROR("HNEMA atom_begin & atom_end must be integers.\n");
      }
      if (modal_analysis.atom_begin > modal_analysis.atom_end) {
        PRINT_INPUT_ERROR("atom_begin must be less than atom_end.\n");
      }
      if (modal_analysis.atom_begin < 0) {
        PRINT_INPUT_ERROR("atom_begin must be greater than 0.\n");
      }
      if (modal_analysis.atom_end >= number_of_types) {
        PRINT_INPUT_ERROR("atom_end must be greater than 0.\n");
      }
    } else {
      PRINT_INPUT_ERROR("Invalid HNEMA keyword.\n");
    }
    printf(
      "    Use select atom range.\n"
      "    Atom types %d to %d.\n",
      modal_analysis.atom_begin, modal_analysis.atom_end);
  } else // default behavior
  {
    modal_analysis.atom_begin = 0;
    modal_analysis.atom_end = number_of_types - 1;
  }
}

void Measure::parse_compute_hnemd(char** param, int num_param)
{
  hnemd.compute = 1;

  printf("Compute thermal conductivity using the HNEMD method.\n");

  if (num_param != 5) {
    PRINT_INPUT_ERROR("compute_hnemd should have 4 parameters.\n");
  }

  if (!is_valid_int(param[1], &hnemd.output_interval)) {
    PRINT_INPUT_ERROR("output_interval for HNEMD should be an integer number.\n");
  }
  printf("    output_interval = %d\n", hnemd.output_interval);
  if (hnemd.output_interval < 1) {
    PRINT_INPUT_ERROR("output_interval for HNEMD should be larger than 0.\n");
  }
  if (!is_valid_real(param[2], &hnemd.fe_x)) {
    PRINT_INPUT_ERROR("fe_x for HNEMD should be a real number.\n");
  }
  printf("    fe_x = %g /A\n", hnemd.fe_x);
  if (!is_valid_real(param[3], &hnemd.fe_y)) {
    PRINT_INPUT_ERROR("fe_y for HNEMD should be a real number.\n");
  }
  printf("    fe_y = %g /A\n", hnemd.fe_y);
  if (!is_valid_real(param[4], &hnemd.fe_z)) {
    PRINT_INPUT_ERROR("fe_z for HNEMD should be a real number.\n");
  }
  printf("    fe_z = %g /A\n", hnemd.fe_z);

  // magnitude of the vector
  hnemd.fe = hnemd.fe_x * hnemd.fe_x;
  hnemd.fe += hnemd.fe_y * hnemd.fe_y;
  hnemd.fe += hnemd.fe_z * hnemd.fe_z;
  hnemd.fe = sqrt(hnemd.fe);
}

void Measure::parse_compute_shc(char** param, int num_param, const std::vector<Group>& group)
{
  printf("Compute SHC.\n");
  shc.compute = 1;

  // check the number of parameters
  if ((num_param != 4) && (num_param != 5) && (num_param != 6)) {
    PRINT_INPUT_ERROR("compute_shc should have 3 or 4 or 5 parameters.");
  }

  // group method and group id
  int offset = 0;
  if (num_param == 4) {
    shc.group_method = -1;
    printf("    for the whole system.\n");
  } else if (num_param == 5) {
    offset = 1;
    shc.group_method = 0;
    if (!is_valid_int(param[1], &shc.group_id)) {
      PRINT_INPUT_ERROR("group id should be an integer.");
    }
    if (shc.group_id < 0) {
      PRINT_INPUT_ERROR("group id should >= 0.");
    }
    if (shc.group_id >= group[0].number) {
      PRINT_INPUT_ERROR("group id should < #groups.");
    }
    printf("    for atoms in group %d.\n", shc.group_id);
    printf("    using grouping method 0.\n");
  } else {
    offset = 2;
    // grouping method
    if (!is_valid_int(param[1], &shc.group_method)) {
      PRINT_INPUT_ERROR("grouping method should be an integer.");
    }
    if (shc.group_method < 0) {
      PRINT_INPUT_ERROR("grouping method should >= 0.");
    }
    if (shc.group_method >= group.size()) {
      PRINT_INPUT_ERROR("grouping method exceeds the bound.");
    }

    // group id
    if (!is_valid_int(param[2], &shc.group_id)) {
      PRINT_INPUT_ERROR("group id should be an integer.");
    }
    if (shc.group_id < 0) {
      PRINT_INPUT_ERROR("group id should >= 0.");
    }
    if (shc.group_id >= group[shc.group_method].number) {
      PRINT_INPUT_ERROR("group id should < #groups.");
    }
    printf("    for atoms in group %d.\n", shc.group_id);
    printf("    using group method %d.\n", shc.group_method);
  }

  // sample interval
  if (!is_valid_int(param[1 + offset], &shc.sample_interval)) {
    PRINT_INPUT_ERROR("Sampling interval for SHC should be an integer.");
  }
  if (shc.sample_interval < 1) {
    PRINT_INPUT_ERROR("Sampling interval for SHC should >= 1.");
  }
  if (shc.sample_interval > 10) {
    PRINT_INPUT_ERROR("Sampling interval for SHC should <= 10 (trust me).");
  }
  printf("    sampling interval for SHC is %d.\n", shc.sample_interval);

  // number of correlation data
  if (!is_valid_int(param[2 + offset], &shc.Nc)) {
    PRINT_INPUT_ERROR("Nc for SHC should be an integer.");
  }
  if (shc.Nc < 100) {
    PRINT_INPUT_ERROR("Nc for SHC should >= 100 (trust me).");
  }
  if (shc.Nc > 1000) {
    PRINT_INPUT_ERROR("Nc for SHC should <= 1000 (trust me).");
  }
  printf("    number of correlation data is %d.\n", shc.Nc);

  // transport direction
  if (!is_valid_int(param[3 + offset], &shc.direction)) {
    PRINT_INPUT_ERROR("direction for SHC should be an integer.");
  }
  if (shc.direction == 0) {
    printf("    transport direction is x.\n");
  } else if (shc.direction == 1) {
    printf("    transport direction is y.\n");
  } else if (shc.direction == 2) {
    printf("    transport direction is z.\n");
  } else {
    PRINT_INPUT_ERROR("Transport direction should be x or y or z.");
  }
}

void Measure::parse_compute(char** param, int num_param, const std::vector<Group>& group)
{
  printf("Compute space and/or time average of:\n");
  if (num_param < 5) {
    PRINT_INPUT_ERROR("compute should have at least 4 parameters.");
  }

  // grouping_method
  if (!is_valid_int(param[1], &compute.grouping_method)) {
    PRINT_INPUT_ERROR("grouping method of compute should be integer.");
  }
  if (compute.grouping_method < 0) {
    PRINT_INPUT_ERROR("grouping method should >= 0.");
  }
  if (compute.grouping_method >= group.size()) {
    PRINT_INPUT_ERROR("grouping method exceeds the bound.");
  }

  // sample_interval
  if (!is_valid_int(param[2], &compute.sample_interval)) {
    PRINT_INPUT_ERROR("sampling interval of compute should be integer.");
  }
  if (compute.sample_interval <= 0) {
    PRINT_INPUT_ERROR("sampling interval of compute should > 0.");
  }

  // output_interval
  if (!is_valid_int(param[3], &compute.output_interval)) {
    PRINT_INPUT_ERROR("output interval of compute should be integer.");
  }
  if (compute.output_interval <= 0) {
    PRINT_INPUT_ERROR("output interval of compute should > 0.");
  }

  // temperature potential force virial jp jk (order is not important)
  for (int k = 0; k < num_param - 4; ++k) {
    if (strcmp(param[k + 4], "temperature") == 0) {
      compute.compute_temperature = 1;
      printf("    temperature\n");
    } else if (strcmp(param[k + 4], "potential") == 0) {
      compute.compute_potential = 1;
      printf("    potential energy\n");
    } else if (strcmp(param[k + 4], "force") == 0) {
      compute.compute_force = 1;
      printf("    force\n");
    } else if (strcmp(param[k + 4], "virial") == 0) {
      compute.compute_virial = 1;
      printf("    virial\n");
    } else if (strcmp(param[k + 4], "jp") == 0) {
      compute.compute_jp = 1;
      printf("    potential part of heat current\n");
    } else if (strcmp(param[k + 4], "jk") == 0) {
      compute.compute_jk = 1;
      printf("    kinetic part of heat current\n");
    } else {
      PRINT_INPUT_ERROR("Invalid property for compute.");
    }
  }

  printf("    using grouping method %d.\n", compute.grouping_method);
  printf("    with sampling interval %d.\n", compute.sample_interval);
  printf("    and output interval %d.\n", compute.output_interval);
}
