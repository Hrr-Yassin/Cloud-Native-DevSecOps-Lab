#!/usr/bin/env bash
case "${LAB_VM_PROFILE:-primary}" in
  primary)
    lab_profile=primary
    lab_instance=devsecops-lab
    lab_data="$PWD/.lab"
    lab_bridge=virbr-dslab
    lab_default_cidr=172.30.88.0/24
    lab_api_port=16443
    ;;
  acceptance)
    lab_profile=acceptance
    lab_instance=devsecops-lab-check
    lab_data="$PWD/.lab/acceptance"
    lab_bridge=virbr-dscheck
    lab_default_cidr=172.30.89.0/24
    lab_api_port=17443
    ;;
  *)
    printf 'LAB_VM_PROFILE must be primary or acceptance.\n' >&2
    return 64
    ;;
esac
