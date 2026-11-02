use std::time::Duration;

use quirewire_domain::BridgeError;

pub trait Clock {
    fn sleep(&mut self, duration: Duration);
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FakeClock {
    pub elapsed: Duration,
    pub sleeps: Vec<Duration>,
}

impl Clock for FakeClock {
    fn sleep(&mut self, duration: Duration) {
        self.elapsed = self.elapsed.saturating_add(duration);
        self.sleeps.push(duration);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RetryPolicy {
    pub max_attempts: u32,
    pub initial_delay: Duration,
    pub max_delay: Duration,
    pub multiplier: u32,
}

impl RetryPolicy {
    #[must_use]
    pub const fn bounded(max_attempts: u32, initial_delay: Duration, max_delay: Duration) -> Self {
        Self {
            max_attempts,
            initial_delay,
            max_delay,
            multiplier: 2,
        }
    }

    #[must_use]
    pub fn delay_before_attempt(&self, attempt_index: u32) -> Duration {
        let exponent = attempt_index.saturating_sub(1).min(31);
        let factor = self.multiplier.saturating_pow(exponent);
        self.initial_delay
            .saturating_mul(factor)
            .min(self.max_delay)
    }
}

pub fn retry_with_clock<T, F, C>(
    policy: RetryPolicy,
    clock: &mut C,
    mut operation: F,
) -> Result<T, BridgeError>
where
    F: FnMut(u32) -> Result<T, BridgeError>,
    C: Clock,
{
    let attempts = policy.max_attempts.max(1);
    for attempt in 1..=attempts {
        match operation(attempt) {
            Ok(value) => return Ok(value),
            Err(error) if error.retryable() && attempt < attempts => {
                clock.sleep(policy.delay_before_attempt(attempt));
            }
            Err(error) => return Err(error),
        }
    }
    unreachable!("attempt count is clamped to at least one")
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use quirewire_domain::BridgeError;

    use super::{FakeClock, RetryPolicy, retry_with_clock};

    #[test]
    fn retries_use_bounded_exponential_backoff() {
        let policy =
            RetryPolicy::bounded(5, Duration::from_millis(100), Duration::from_millis(250));
        let mut clock = FakeClock::default();
        let result = retry_with_clock(policy, &mut clock, |attempt| {
            if attempt < 4 {
                Err(BridgeError::Timeout {
                    operation: "fake".into(),
                    seconds: 1,
                })
            } else {
                Ok(attempt)
            }
        });
        assert_eq!(result.expect("fourth attempt should succeed"), 4);
        assert_eq!(
            clock.sleeps,
            [
                Duration::from_millis(100),
                Duration::from_millis(200),
                Duration::from_millis(250)
            ]
        );
    }

    #[test]
    fn non_retryable_error_stops_immediately() {
        let policy = RetryPolicy::bounded(5, Duration::from_secs(1), Duration::from_secs(5));
        let mut clock = FakeClock::default();
        let error = retry_with_clock::<(), _, _>(policy, &mut clock, |_| {
            Err(BridgeError::PermissionDenied {
                operation: "fake".into(),
                action: "none".into(),
            })
        })
        .expect_err("permission error should not retry");
        assert_eq!(error.kind().as_str(), "permission_denied");
        assert!(clock.sleeps.is_empty());
    }
}
