#!/bin/bash
set -e
export CUDA_VISIBLE_DEVICES=4


TOP="/nfs/mathusalem/maxence/sfinke/autoheatC+/3FIQPro.prmtop"
START_RST="/nfs/mathusalem/maxence/sfinke/autoheatC+/Min3FIQ.ncrst"   # minimized coords (no velocities)
NP_MPI=8




# ---- MD constants ----
DT_PS=0.002
STEPS_PER_NS=500000                 # 1 ns / 0.002 ps
INIT_HEAT_NS=1
HEAT_NS=1
PROD_NS=10

INIT_HEAT_STEPS=$(( INIT_HEAT_NS * STEPS_PER_NS ))
HEAT_STEPS=$(( HEAT_NS * STEPS_PER_NS ))
PROD_STEPS=$(( PROD_NS * STEPS_PER_NS ))

# Output cadence
NTPR=10000     # print every 20 ps (production)
NTWX=10000     # trajectory every 20 ps (production)
NTWR=500000    # checkpoint every 1 ns during production

# Temperature schedule:
#  - initial: 100 -> 300 (one-time)
#  - cycle:   300 -> 500 in +10 K steps: 310, 320, ..., 500
START_T=300
TARGETS=()
for t in $(seq 310 10 600); do TARGETS+=($t); done

prev_rst="$START_RST"

echo "=== Initial heating: 100 K -> 300 K (1 ns, NVT) ==="
cat > init_heating.in <<EOF
Initial heat 100->300 K (1 ns)
 &cntrl
  imin=0,
  ntx=1, irest=0,
  nstlim=${INIT_HEAT_STEPS},
  dt=${DT_PS},
  ntf=2, ntc=2,
  tempi=100.0,        ! start velocities at 100 K
  temp0=300.0,
  ntpr=50000,         ! << less output during heating (every 100 ps)
  ntwx=0,             ! << no trajectory during heating
  cut=8.0,
  ntb=1, ntp=0,       ! NVT
  ntt=3, gamma_ln=2.0,
  nmropt=1,
  ig=-1,
/
&wt type='TEMP0', istep1=0, istep2=${INIT_HEAT_STEPS}, value1=0.0, value2=300.0 /
&wt type='END' /
EOF

init_tag="heat_0K_to_300K_1ns"
pmemd.cuda -O \
  -i init_heating.in -o ${init_tag}.out \
  -p "$TOP" -c "${prev_rst}" \
  -r ${init_tag}.ncrst -x ${init_tag}.nc -inf ${init_tag}.mdinfo

prev_rst="${init_tag}.ncrst"

echo "=== Initial production: 300 K (${PROD_NS} ns, NPT) ==="
cat > production.in <<EOF
Production 300 K (${PROD_NS} ns)
 &cntrl
  imin=0,
  ntx=5, irest=1,
  nstlim=${PROD_STEPS},
  dt=${DT_PS},
  ntf=2, ntc=2,
  temp0=300.0,
  ntpr=${NTPR},
  ntwx=${NTWX},
  ntwr=${NTWR},
  cut=8.0,
  ntb=2,
  ntp=1,
  ntt=3, barostat=2,
  gamma_ln=2.0,
  ig=-1,
 /
EOF

prod0_tag="prod_300K_${PROD_NS}ns"
pmemd.cuda -O \
  -i production.in -o ${prod0_tag}.out \
  -p "$TOP" -c "${prev_rst}" \
  -r ${prod0_tag}.ncrst -x ${prod0_tag}.nc -inf ${prod0_tag}.mdinfo

prev_rst="${prod0_tag}.ncrst"
current_T=${START_T}

# ====== Cyclic +10 K heating (1 ns) and production up to 600 K ======
cycle_idx=1
for tgt in "${TARGETS[@]}"; do
  CYC_DIR=$(printf "cycle%02d" "$cycle_idx")
  mkdir -p "$CYC_DIR"

  echo "=== Heating: ${current_T} K -> ${tgt} K (1 ns, NVT) into ${CYC_DIR}/ ==="
  cat > "${CYC_DIR}/heating.in" <<EOF
Heat ${current_T}->${tgt} K (1 ns)
 &cntrl
  imin=0,
  ntx=5, irest=1,
  nstlim=${HEAT_STEPS},
  dt=${DT_PS},
  ntf=2, ntc=2,
  temp0=${tgt}.0,
  ntpr=50000,         ! << less output during heating
  ntwx=0,             ! << no trajectory during heating
  cut=8.0,
  ntb=1, ntp=0,       ! NVT for heating
  ntt=3, gamma_ln=2.0,
  nmropt=1,
  ig=-1,
/
&wt type='TEMP0', istep1=0, istep2=${HEAT_STEPS}, value1=${current_T}.0, value2=${tgt}.0 /
&wt type='END' /
EOF

  heat_tag="${CYC_DIR}/heat_${current_T}K_to_${tgt}K_1ns"
  pmemd.cuda -O \
    -i "${CYC_DIR}/heating.in" -o "${heat_tag}.out" \
    -p "$TOP" -c "${prev_rst}" \
    -r "${heat_tag}.ncrst" -x "${heat_tag}.nc" -inf "${heat_tag}.mdinfo"

  prev_rst="${heat_tag}.ncrst"
  current_T=$tgt

  echo "=== Production: ${current_T} K (${PROD_NS} ns, NPT) into ${CYC_DIR}/ ==="
  cat > "${CYC_DIR}/production.in" <<EOF
Production ${current_T} K (${PROD_NS} ns)
 &cntrl
  imin=0,
  ntx=5, irest=1,
  nstlim=${PROD_STEPS},
  dt=${DT_PS},
  ntf=2, ntc=2,
  temp0=${current_T}.0,
  ntpr=${NTPR},
  ntwx=${NTWX},
  ntwr=${NTWR},
  cut=8.0,
  ntb=2,
  ntp=1,
  ntt=3, barostat=2,
  gamma_ln=2.0,
  ig=-1,
 /
EOF

  prod_tag="${CYC_DIR}/prod_${current_T}K_${PROD_NS}ns"
  pmemd.cuda -O \
    -i "${CYC_DIR}/production.in" -o "${prod_tag}.out" \
    -p "$TOP" -c "${prev_rst}" \
    -r "${prod_tag}.ncrst" -x "${prod_tag}.nc" -inf "${prod_tag}.mdinfo"

  prev_rst="${prod_tag}.ncrst"

  # (optional) quick pointer to latest restart
  ln -sf "$(realpath "${prev_rst}")" latest.rst

  cycle_idx=$((cycle_idx+1))
done

echo "Initial 100->300 K heat + ${PROD_NS} ns production done, and all cycles up to ${current_T} K completed."
