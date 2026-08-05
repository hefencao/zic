//! Best-effort Android decode-thread placement.
//!
//! Android EAS may keep long-lived background-origin workers on efficiency
//! cores after the app returns to foreground. The caller invokes this exactly
//! once from each process-lifetime decode worker. Failure is non-fatal.

#[cfg(target_os = "android")]
mod imp {
    use std::fs;
    use std::mem::size_of;
    use std::sync::OnceLock;

    const CPU_SET_BITS: usize = 1024;
    const WORD_BITS: usize = usize::BITS as usize;
    const CPU_SET_WORDS: usize = CPU_SET_BITS / WORD_BITS;
    const MAX_PROBED_CPUS: usize = 256;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CpuSet {
        words: [usize; CPU_SET_WORDS],
    }

    impl CpuSet {
        const fn empty() -> Self {
            Self {
                words: [0; CPU_SET_WORDS],
            }
        }

        fn insert(&mut self, cpu: usize) {
            if cpu >= CPU_SET_BITS {
                return;
            }
            self.words[cpu / WORD_BITS] |= 1usize << (cpu % WORD_BITS);
        }
    }

    extern "C" {
        fn sched_setaffinity(pid: i32, cpusetsize: usize, mask: *const CpuSet) -> i32;
    }

    static PERFORMANCE_MASK: OnceLock<Option<CpuSet>> = OnceLock::new();

    fn read_frequency(cpu: usize) -> Option<u64> {
        for name in ["cpuinfo_max_freq", "scaling_max_freq"] {
            let path = format!(
                "/sys/devices/system/cpu/cpu{cpu}/cpufreq/{name}"
            );
            let Ok(text) = fs::read_to_string(path) else {
                continue;
            };
            if let Ok(value) = text.trim().parse::<u64>() {
                if value > 0 {
                    return Some(value);
                }
            }
        }
        None
    }

    fn compute_mask() -> Option<CpuSet> {
        let mut frequencies = Vec::<(usize, u64)>::new();
        for cpu in 0..MAX_PROBED_CPUS {
            if let Some(frequency) = read_frequency(cpu) {
                frequencies.push((cpu, frequency));
            }
        }
        let max_frequency = frequencies.iter().map(|(_, value)| *value).max()?;
        let threshold = max_frequency.saturating_mul(8) / 10;
        let mut mask = CpuSet::empty();
        let mut selected = 0usize;
        for (cpu, frequency) in &frequencies {
            if *frequency >= threshold {
                mask.insert(*cpu);
                selected += 1;
            }
        }
        // Do not bind homogeneous devices or incomplete one-cluster probes.
        if selected == 0 || selected >= frequencies.len() {
            return None;
        }
        Some(mask)
    }

    /// 1=applied, 2=no heterogeneous high-performance mask, 3=OS rejected.
    pub fn prepare_current_thread() -> u32 {
        let Some(mask) = PERFORMANCE_MASK.get_or_init(compute_mask).as_ref() else {
            return 2;
        };
        // Linux pid=0 means the calling thread for sched_setaffinity.
        let result = unsafe { sched_setaffinity(0, size_of::<CpuSet>(), mask) };
        if result == 0 { 1 } else { 3 }
    }
}

#[cfg(not(target_os = "android"))]
mod imp {
    /// Host builds intentionally retain normal scheduler placement.
    pub fn prepare_current_thread() -> u32 {
        0
    }
}

pub(crate) use imp::prepare_current_thread;
