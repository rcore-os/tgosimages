#pragma once

/*
 * Optional ABI supplied by aka-rk3588.  The shell remains buildable without
 * the external library; when linked, these weak hooks are resolved by AKA.
 */
int aka_adapter_run();

const char *aka_adapter_state();
int aka_adapter_result();
