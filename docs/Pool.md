# Pool contract

Pool is the heart of protocol, which hold all LP's assets and control traders' positions.

## 1 Tranche

Tranche is a logical division of pool. The assets is mamaged by tranche. They have their all pool amount and positions share.

Tranche store these values of each token

- Pool amount: the token amount in which trader can open position. Everytime trader open a position, an amount of token is reserved from pool amount, and returned when they close their positions.
- Reserved amount: the amount of token reserved to pay to trader when they closed their position
- totalShortSize, avgShortPrice: size and entry price of a pseudo short position, used to calculate total PnL of all short positions
- GuaranteedValue: Total different between position size and collateral value at the time trader open their position, used to calculate total PnL of long position. For each position, guaranteed value is calculated as
  $$
  G = S - C\\
  $$
  The GuaranteedValue of tranche is simply total of all guaranteed value of all position
- Managed value: the value in dollar of all controlled by hold by pool at any given moment, even if all traders close their position at this point of time. More on that later.

## 2. Pricing

- Token price is returned from oracle in decimals of (30 - token_decimals). In this way all value of token (calculated as token_amount * token_price) will have their decimals of 30.

## 3. Position

Position = (owner, index_token, collateral_token, side, collateral_value, size)
All position param is value in dollar of token.
Trader open position by depositing an amount of collateral token, in contrast protocol will reserved an amount of the same token. In case of LONG, collateral token is same as index token. In case of SHORT, they must deposit a stable coin. In this way, protocol minimize the risk of value lost, because in any market condition, the reserved amount will be enough to pay to the trader.

### PnL

Profit and Lost of a position is calculated from index token price

$$
PnL = \frac{(entryPrice - markPrice) \times side \times size}{entryPrice}
$$

$$
side = \begin{cases}
  1, & \text {if side = LONG}\\
  -1, & \text {if side = SHORT}
\end{cases}
$$

**NOTE**: We define $markPrice$ is the price of index token at the time of observation.

### Fee

Combine of position fee and margin fee (the fee of borrowing assets as margin)

$$
positionFee = positionSize * positionFeeRate
marginFee = positionSize * marginFeeRate
$$

In which

- $positionFeeRate$ is fixed
- $marginFeeRate = \frac{reservedAmount \times borrowInterestRate }{poolAmount}$

The margin_fee_rate is changed each accrue interval, therefore it's stored as accumulated value, called borrow_index, similar to what Compound does. So the margin_fee is calculated as:

$$
borrowIndex = borrowIndex + marginFeeRate \times \Delta t \\
marginFee = positionSize \times \Delta borrowIndex
$$

with $\Delta t$ is number of accrual interval past.

### Entry price

Entry price changed each time trader increase their position, and not changed if they decrease their position, so the position's PnL kept.

Let $P^{'}_0$ is new entry price, $\Delta S$ is the size increased, with LONG position:

$$
PnL = \frac{P - P^{'}_0}{P^{'}_0} \times (S + \Delta S) \\
\Rightarrow P^{'}_0 = \frac{(S + \Delta S) \times P}{S + \Delta S + PnL}
$$

Similar with SHORT position

$$
\Rightarrow P^{'}_0 = \frac{(S + \Delta S) \times P}{S + \Delta S - PnL}
$$

## 4. Managed value

We define managed value is total value in dollar of all assets pool actual hold if all traders close their positions in any given time. So the value is sum of value of all tokens deposited by LP, collateral deposited by trader; minus collateral and profit paid to user when they close their position.

In case of long position, we hold index token as collateral, so the value of token in pool is

$$
(D + c) \times P
$$

with:
$D$ amount LP deposited
$c$ collateral by trader
$P$ mark price

And we must pay trader
$$
PnL + C
$$

with $C = c \times P_0$ is value of collateral at time of opening position

So the managed value

$$
ManagedValue = (D + c) \times P - PnL - C \\
= (D + c) \times P - \frac{(P - P_0) \times S}{P_0} - C \\
= (D + c) \times P - (\frac{S}{P_0}) \times P + (S - C) \\
= (D + c - (\frac{S}{P_0})) \times P + (S - C)
$$

Note that we already have

- $D + c$ = pool amount
- $(\frac{S}{P_0})$ = reserve
- $S-C$ = guaranteed value

So

$$
ManagedValue = (poolAmount - reserve) \times indexPrice - guaranteedValue
$$

Guaranteed value is calculated in cumulative style each time long position updated.

Now we need to add value of the short positions.This time we use stable coin as collateral, so the value is

$$
ManagedValue = (D_1 + c) \times P_1 - \frac{(P_0 - P) \times S}{P_0} - c \times P_1
$$

with $P_1$ is stable coin price, $D_1$ is amount of stable coin token deposited by LP.

$$
ManagedValue = D_1 \times P_1 - \frac{(P_0 - P) \times S}{P_0}
$$

$$
ManagedValue = stablePoolAmount \times stablePrice - globalShortPnL
$$

Therefore we need to calculate and store a pseudo global short position. This position is updated whenever a short position updated.
