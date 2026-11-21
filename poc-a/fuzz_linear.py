import random

def div_ceil(a,b): return (a+b-1)//b

def max_end(payoutStart, interval, initial, decrease):
    if decrease==0: return (1<<128)-1
    return payoutStart + div_ceil(initial, decrease)*interval

def part_reward(payoutStart, startTime, interval, initial, decrease, toEnd):
    intervalsPassed = (startTime-payoutStart)//interval
    dec = intervalsPassed*decrease
    if dec >= initial: return 0
    full = initial-dec
    if toEnd:
        part = interval*(intervalsPassed+1)+payoutStart-startTime
    else:
        part = startTime - interval*intervalsPassed - payoutStart
    if part==interval: return 0
    return (full*part)//interval

def full_reward(payoutStart, startTime, endTime, interval, initial, decrease):
    timePassedBefore = startTime-payoutStart
    intervalsPassedBefore = div_ceil(timePassedBefore, interval)
    dec = intervalsPassedBefore*decrease
    if dec >= initial: return 0
    initialReward = initial-dec
    ip = (endTime-payoutStart-intervalsPassedBefore*interval)//interval
    if ip==0: return 0
    return initialReward*ip - decrease*((ip*(ip-1))//2)

def get_period_reward(initial, decrease, payoutStart, interval, startTime, endTime):
    if interval==0: return 0
    if startTime < payoutStart: startTime = payoutStart
    me = max_end(payoutStart, interval, initial, decrease)
    if endTime > me: endTime = me
    if startTime >= endTime: return 0
    timePassedBefore = startTime-payoutStart
    if (timePassedBefore//interval) == ((endTime-payoutStart)//interval):
        intervalsPassed = timePassedBefore//interval
        full = initial - intervalsPassed*decrease
        return (full*(endTime-startTime))//interval
    return (part_reward(payoutStart,startTime,interval,initial,decrease,True)
            + full_reward(payoutStart,startTime,endTime,interval,initial,decrease)
            + part_reward(payoutStart,endTime,interval,initial,decrease,False))

def brute(initial, decrease, payoutStart, interval, startTime, endTime):
    # exact rational sum per second, floored once at end (upper bound of per-interval flooring)
    from fractions import Fraction
    if startTime < payoutStart: startTime = payoutStart
    me = max_end(payoutStart, interval, initial, decrease)
    if endTime > me: endTime = me
    if startTime >= endTime: return 0
    total = Fraction(0)
    t = startTime
    while t < endTime:
        k = (t-payoutStart)//interval
        rate = initial - k*decrease
        if rate <= 0: break
        seg_end = min(endTime, payoutStart+(k+1)*interval)
        total += Fraction(rate*(seg_end-t), interval)
        t = seg_end
    return total  # Fraction

random.seed(42)
worst_over = 0; worst_under = 0; worst_case=None; n=0
for trial in range(3000):
    payoutStart = random.randint(0, 10**6)
    interval = random.choice([1,7,100,3600,86400])
    initial = random.randint(1, 10**6) * 10**18
    decrease = random.randint(0, initial//10 + 1)
    startTime = payoutStart + random.randint(0, 50*interval)
    endTime = startTime + random.randint(0, 50*interval)
    got = get_period_reward(initial, decrease, payoutStart, interval, startTime, endTime)
    exact = brute(initial, decrease, payoutStart, interval, startTime, endTime)
    n+=1
    # contract floors per segment (<=3 segments + per full interval arithmetic is exact integer);
    # allow tolerance of a few wei per segment division. Over-issuance = got > exact.
    diff = got - exact  # Fraction
    if diff > worst_over:
        worst_over = diff; worst_case=(initial,decrease,payoutStart,interval,startTime,endTime,got,float(exact))
    if diff < worst_under:
        worst_under = diff
print(f"trials={n} worst_over_issuance_wei={worst_over} worst_under={worst_under}")
if worst_case: print("worst case:", worst_case)

# Targeted: on-chain pool0 params
initial=3456000000000000000000; decrease=592558728240000000; payoutStart=1707393600; interval=86400
# total emission over full schedule via contract fn vs exact
me = max_end(payoutStart, interval, initial, decrease)
got = get_period_reward(initial, decrease, payoutStart, interval, payoutStart, me)
exact = brute(initial, decrease, payoutStart, interval, payoutStart, me)
print(f"pool0 full schedule: contract={got} exact={float(exact)} diff={got-exact}")
# additivity: split period in two, sum vs whole (distributeRewards calls sequentially)
worst_add=0; wc=None
for trial in range(2000):
    a = payoutStart + random.randint(0, 5000*86400)
    b = a + random.randint(0, 100*86400)
    c = b + random.randint(0, 100*86400)
    whole = get_period_reward(initial, decrease, payoutStart, interval, a, c)
    parts = get_period_reward(initial, decrease, payoutStart, interval, a, b) + get_period_reward(initial, decrease, payoutStart, interval, b, c)
    if parts-whole > worst_add:
        worst_add = parts-whole; wc=(a,b,c,whole,parts)
print(f"additivity worst over (parts-whole) wei={worst_add} case={wc}")
