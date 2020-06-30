pragma solidity ^0.6.0;

import "@hq20/contracts/contracts/utils/SafeCast.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IVat.sol";
import "./interfaces/IDaiJoin.sol";
import "./interfaces/IGemJoin.sol";
import "./interfaces/IJug.sol";
import "./interfaces/IPot.sol";
import "./interfaces/IEnd.sol";
import "./interfaces/IChai.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IDealer.sol";
import "./interfaces/IYDai.sol";
import "./interfaces/ILiquidations.sol";
import "./Constants.sol";
// import "@nomiclabs/buidler/console.sol";


/// @dev Treasury manages the Dai, interacting with MakerDAO's vat and chai when needed.
contract Shutdown is Ownable(), Constants {
    using SafeCast for uint256;
    using SafeMath for uint256;

    bytes32 public constant collateralType = "ETH-A";
    uint256 public constant UNIT = 1000000000000000000000000000;

    IVat internal _vat;
    IDaiJoin internal _daiJoin;
    IERC20 internal _weth;
    IGemJoin internal _wethJoin;
    IJug internal _jug;
    IPot internal _pot;
    IEnd internal _end;
    IChai internal _chai;
    IOracle internal _chaiOracle;
    ITreasury internal _treasury;
    IDealer internal _dealer;
    ILiquidations internal _liquidations;

    // TODO: Series related code is repeated with Dealer, can be extracted into a parent class.
    mapping(uint256 => IYDai) public series; // YDai series, indexed by maturity
    uint256[] internal seriesIterator;       // We need to know all the series

    uint256 public _fix; // Dai to weth price on DSS Shutdown
    uint256 public _chi; // Chai to dai price on DSS Shutdown

    bool public settled;
    bool public cashedOut;
    bool public live = true;

    constructor (
        address vat_,
        address daiJoin_,
        address weth_,
        address wethJoin_,
        address jug_,
        address pot_,
        address end_,
        address chai_,
        address chaiOracle_,
        address treasury_,
        address dealer_,
        address liquidations_
    ) public {
        // These could be hardcoded for mainnet deployment.
        _vat = IVat(vat_);
        _daiJoin = IDaiJoin(daiJoin_);
        _weth = IERC20(weth_);
        _wethJoin = IGemJoin(wethJoin_);
        _jug = IJug(jug_);
        _pot = IPot(pot_);
        _end = IEnd(end_);
        _chai = IChai(chai_);
        _chaiOracle = IOracle(chaiOracle_);
        _treasury = ITreasury(treasury_);
        _dealer = IDealer(dealer_);
        _liquidations = ILiquidations(liquidations_);

        _vat.hope(address(_treasury));
        _vat.hope(address(_end));
    }

    /// @dev Multiplies x and y, assuming they are both fixed point with 27 digits.
    function muld(uint256 x, uint256 y) internal pure returns (uint256) {
        return x.mul(y).div(UNIT);
    }

    /// @dev Divides x between y, assuming they are both fixed point with 18 digits.
    function divd(uint256 x, uint256 y) internal pure returns (uint256) {
        return x.mul(UNIT).div(y);
    }

    /// @dev max(0, x - y)
    function subFloorZero(uint256 x, uint256 y) public pure returns(uint256) {
        if (y >= x) return 0;
        else return x - y;
    }

    /// @dev Returns if a series has been added to the Dealer, for a given series identified by maturity
    function containsSeries(uint256 maturity) public view returns (bool) {
        return address(series[maturity]) != address(0);
    }

    /// @dev Adds an yDai series to this Dealer
    function addSeries(address yDaiContract) public onlyOwner {
        uint256 maturity = IYDai(yDaiContract).maturity();
        require(
            !containsSeries(maturity),
            "Dealer: Series already added"
        );
        series[maturity] = IYDai(yDaiContract);
        seriesIterator.push(maturity);
    }

    /// @dev Disables treasury and dealer.
    function shutdown() public {
        require(
            _end.tag(collateralType) != 0,
            "Shutdown: MakerDAO not shutting down"
        );
        live = false;
        _treasury.shutdown();
        _dealer.shutdown();
        _liquidations.shutdown();
    }

    function getChi() public returns (uint256) {
        return (now > _pot.rho()) ? _pot.drip() : _pot.chi();
    }

    function getRate() public returns (uint256) {
        uint256 rate;
        (, uint256 rho) = _jug.ilks("ETH-A"); // "WETH" for weth.sol, "ETH-A" for MakerDAO
        if (now > rho) {
            rate = _jug.drip("ETH-A");
        } else {
            (, rate,,,) = _vat.ilks("ETH-A");
        }
        return rate;
    }

    /// @dev Calculates how much profit is in the system and transfers it to the beneficiary
    function skim(address beneficiary) public { // TODO: Hardcode
        require(
            live == true,
            "Shutdown: Can only skim if live"
        );

        uint256 profit = _chai.balanceOf(address(_treasury));
        profit = profit.add(yDaiProfit());
        profit = profit.sub(divd(_treasury.debt(), getChi()));
        profit = profit.sub(_dealer.systemPosted(CHAI));

        _treasury.pullChai(beneficiary, profit);
    }

    /// @dev Returns the profit accummulated in the system due to yDai supply and debt, in chai.
    function yDaiProfit() public returns (uint256) {
        uint256 profit;
        uint256 chi = getChi();
        uint256 rate = getRate();

        for (uint256 i = 0; i < seriesIterator.length; i += 1) {
            uint256 maturity = seriesIterator[i];
            IYDai yDai = IYDai(series[seriesIterator[i]]);

            uint256 chi0;
            uint256 rate0;
            if (yDai.isMature()){
                chi0 = yDai.chi0();
                rate0 = yDai.rate0();
            } else {
                chi0 = chi;
                rate0 = rate;
            }

            profit = profit.add(divd(muld(_dealer.systemDebtYDai(WETH, maturity), divd(rate, rate0)), chi0));
            profit = profit.add(divd(_dealer.systemDebtYDai(CHAI, maturity), chi0));
            profit = profit.sub(divd(yDai.totalSupply(), chi0));
        }

        return profit;
    }

    /// @dev Settle system debt in MakerDAO and free remaining collateral.
    function settleTreasury() public {
        require(
            live == false,
            "Shutdown: Shutdown first"
        );
        (uint256 ink, uint256 art) = _vat.urns("ETH-A", address(_treasury));
        _vat.fork(                                               // Take the treasury vault
            collateralType,
            address(_treasury),
            address(this),
            ink.toInt(),
            art.toInt()
        );
        _end.skim(collateralType, address(this));                // Settle debts
        _end.free(collateralType);                               // Free collateral
        uint256 gem = _vat.gem("ETH-A", address(this));          // Find out how much collateral we have now
        _wethJoin.exit(address(this), gem);                      // Take collateral out
        settled = true;
    }

    /// @dev Put all chai savings in MakerDAO and exchange them for weth
    function cashSavings() public {
        require(
            _end.tag(collateralType) != 0,
            "Shutdown: End.sol not caged"
        );
        require(
            _end.fix(collateralType) != 0,
            "Shutdown: End.sol not ready"
        );
        uint256 daiTokens = _chai.dai(address(_treasury));   // Find out how much is the chai worth
        _chai.draw(address(_treasury), _treasury.savings()); // Get the chai as dai
        _daiJoin.join(address(this), daiTokens);             // Put the dai into MakerDAO
        _end.pack(daiTokens);                                // Into End.sol, more exactly
        _end.cash(collateralType, daiTokens);                // Exchange the dai for weth
        uint256 gem = _vat.gem("ETH-A", address(this));      // Find out how much collateral we have now
        _wethJoin.exit(address(this), gem);                  // Take collateral out
        cashedOut = true;

        _fix = _end.fix(collateralType);
        _chi = _chaiOracle.price();
    }

    /// @dev Settles a series position in Dealer, and then returns any remaining collateral as weth using the shutdown Dai to Weth price.
    function settle(bytes32 collateral, address user) public {
        require(settled && cashedOut, "Shutdown: Not ready");
        (uint256 tokenAmount, uint256 daiAmount) = _dealer.erase(collateral, user);
        uint256 remainder;
        if (collateral == WETH) {
            remainder = subFloorZero(tokenAmount, muld(daiAmount, _fix));
        } else if (collateral == CHAI) {
            remainder = muld(subFloorZero(muld(tokenAmount, _chi), daiAmount), _fix);
        }
        _weth.transfer(user, remainder);
    }

    /// @dev Redeems YDai for weth
    function redeem(uint256 maturity, uint256 yDaiAmount, address user) public {
        require(settled && cashedOut, "Shutdown: Not ready");
        IYDai yDai = _dealer.series(maturity);
        yDai.burn(user, yDaiAmount);
        _weth.transfer(
            user,
            muld(muld(yDaiAmount, yDai.chiGrowth()), _fix)
        );
    }

    /// @dev Calculates how much profit is in the system and transfers it to the beneficiary
    function skimShutdown(address beneficiary) public { // TODO: Hardcode
        require(settled && cashedOut, "Shutdown: Not ready");

        uint256 chi = getChi();
        uint256 profit = _weth.balanceOf(address(this));

        profit = profit.add(muld(muld(yDaiProfit(), _fix), chi));
        profit = profit.sub(_dealer.systemPosted(WETH));
        profit = profit.sub(muld(muld(_dealer.systemPosted(CHAI), _fix), chi));

        _weth.transfer(beneficiary, profit);
    }
}