// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract DCAI is IERC20 {
    using SafeERC20 for IERC20;
    mapping(address => uint256) private _tOwned;
    mapping(address => bool) lpPairs;
    uint256 private timeSinceLastPair = 0;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) private _liquidityHolders;
    mapping(address => bool) private _isExcludedFromProtection;
    mapping(address => bool) private _isExcludedFromFees;
    uint256 private constant startingSupply = 1_000_000_000;
    string private constant _name = "Decentralverse AI";
    string private constant _symbol = "DCAI";
    uint8 private constant _decimals = 9;
    uint256 private constant _tTotal = startingSupply * 10 ** _decimals;

    struct Fees {
        uint16 buyFee;
        uint16 sellFee;
        uint16 transferFee;
    }

    struct Ratios {
        uint16 marketing;
        uint16 development;
        uint16 team;
        uint16 ecosystem;
        uint16 totalSwap;
    }

    Fees public _taxRates = Fees({buyFee: 400, sellFee: 400, transferFee: 0});

    Ratios public _ratios =
        Ratios({
            marketing: 1,
            development: 1,
            team: 2,
            ecosystem: 4,
            totalSwap: 8
        });

    uint256 constant masterTaxDivisor = 10000;

    // Quickswap V2 Router
    IUniswapV2Router02 public dexRouter =
        IUniswapV2Router02(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);
    address public lpPair;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct TaxWallets {
        address payable marketing;
        address payable development;
        address payable team;
        address payable ecosystem;
    }

    TaxWallets public _taxWallets =
        TaxWallets({
            marketing: payable(0xc96eE6110F7264da61c07179E502DCE3BC43d02a),
            development: payable(0x4A9FcEB6818CfcBF5e122B4710c142cC11F8e052),
            team: payable(0x1762AE95D24164dA2fd8041F799031532699541f),
            ecosystem: payable(0x55A201a36610CeC0073f23119B520a456E330868)
        });

    bool inSwap;
    bool public contractSwapEnabled = false;
    uint256 public swapThreshold;
    uint256 public swapAmount;
    bool public piContractSwapsEnabled;
    uint256 public piSwapPercent = 10;
    bool public tradingEnabled = false;
    bool public _hasLiqBeenAdded = false;
    address initializer;
    uint256 public launchStamp;

    address public constant USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;

    event ContractSwapEnabledUpdated(bool enabled);
    event AutoLiquify(uint256 amountCurrency, uint256 amountTokens);

    modifier inSwapFlag() {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor() payable {
        // Set the owner.
        _owner = msg.sender;

        _tOwned[_owner] = _tTotal;
        emit Transfer(address(0), _owner, _tTotal);

        _isExcludedFromFees[_owner] = true;
        _isExcludedFromFees[address(this)] = true;
        _isExcludedFromFees[DEAD] = true;
        _liquidityHolders[_owner] = true;
    }

    //===============================================================================================================
    //===============================================================================================================
    //===============================================================================================================
    // Ownable removed as a lib and added here to allow for custom transfers and renouncements.
    // This allows for removal of ownership privileges from the owner once renounced or transferred.

    address private _owner;

    modifier onlyOwner() {
        require(_owner == msg.sender, "Caller =/= owner.");
        _;
    }
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    function transferOwner(address newOwner) external onlyOwner {
        require(
            newOwner != address(0),
            "Call renounceOwnership to transfer owner to the zero address."
        );
        require(
            newOwner != DEAD,
            "Call renounceOwnership to transfer owner to the zero address."
        );
        _isExcludedFromFees[_owner] = false;
        _isExcludedFromFees[newOwner] = true;

        if (balanceOf(_owner) > 0) {
            finalizeTransfer(
                _owner,
                newOwner,
                balanceOf(_owner),
                false,
                false,
                true
            );
        }

        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function renounceOwnership() external onlyOwner {
        require(
            tradingEnabled,
            "Cannot renounce until trading has been enabled."
        );
        _isExcludedFromFees[_owner] = false;
        address oldOwner = _owner;
        _owner = address(0);
        emit OwnershipTransferred(oldOwner, address(0));
    }

    //===============================================================================================================
    //===============================================================================================================
    //===============================================================================================================

    receive() external payable {}

    function totalSupply() external pure override returns (uint256) {
        return _tTotal;
    }

    function decimals() external pure returns (uint8) {
        return _decimals;
    }

    function symbol() external pure returns (string memory) {
        return _symbol;
    }

    function name() external pure returns (string memory) {
        return _name;
    }

    function getOwner() external view returns (address) {
        return _owner;
    }

    function allowance(
        address holder,
        address spender
    ) external view override returns (uint256) {
        return _allowances[holder][spender];
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _tOwned[account];
    }

    function transfer(
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function approve(
        address spender,
        uint256 amount
    ) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function _approve(
        address sender,
        address spender,
        uint256 amount
    ) internal {
        require(sender != address(0), "ERC20: Zero Address");
        require(spender != address(0), "ERC20: Zero Address");

        _allowances[sender][spender] = amount;
        emit Approval(sender, spender, amount);
    }

    function approveContractContingency() external onlyOwner returns (bool) {
        _approve(address(this), address(dexRouter), type(uint256).max);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external override returns (bool) {
        if (_allowances[sender][msg.sender] != type(uint256).max) {
            _allowances[sender][msg.sender] -= amount;
        }

        return _transfer(sender, recipient, amount);
    }

    function setNewRouter(address newRouter) external onlyOwner {
        require(!_hasLiqBeenAdded, "Cannot change after liquidity.");
        IUniswapV2Router02 _newRouter = IUniswapV2Router02(newRouter);
        address get_pair = IUniswapV2Factory(_newRouter.factory()).getPair(
            address(this),
            _newRouter.WETH()
        );
        lpPairs[lpPair] = false;
        if (get_pair == address(0)) {
            lpPair = IUniswapV2Factory(_newRouter.factory()).createPair(
                address(this),
                _newRouter.WETH()
            );
        } else {
            lpPair = get_pair;
        }
        dexRouter = _newRouter;
        lpPairs[lpPair] = true;
        _approve(address(this), address(dexRouter), type(uint256).max);
    }

    function setLpPair(address pair, bool enabled) external onlyOwner {
        if (!enabled) {
            lpPairs[pair] = false;
        } else {
            if (timeSinceLastPair != 0) {
                require(
                    block.timestamp - timeSinceLastPair > 3 days,
                    "3 Day cooldown."
                );
            }
            require(!lpPairs[pair], "Pair already added to list.");
            lpPairs[pair] = true;
            timeSinceLastPair = block.timestamp;
        }
    }

    function setInitializer(address init) public onlyOwner {
        require(!tradingEnabled);
        require(init != address(this), "Can't be self.");
        initializer = init;
        address get_pair = IUniswapV2Factory(dexRouter.factory()).getPair(
            address(this),
            dexRouter.WETH()
        );
        if (get_pair == address(0)) {
            lpPair = IUniswapV2Factory(dexRouter.factory()).createPair(
                address(this),
                dexRouter.WETH()
            );
        } else {
            lpPair = get_pair;
        }
        lpPairs[lpPair] = true;
        _approve(_owner, address(dexRouter), type(uint256).max);
        _approve(address(this), address(dexRouter), type(uint256).max);
    }

    function isExcludedFromFees(address account) external view returns (bool) {
        return _isExcludedFromFees[account];
    }

    function isExcludedFromProtection(
        address account
    ) external view returns (bool) {
        return _isExcludedFromProtection[account];
    }

    function getCirculatingSupply() public view returns (uint256) {
        return (_tTotal - (balanceOf(DEAD) + balanceOf(address(0))));
    }

    function getTokenAmountAtPriceImpact(
        uint256 priceImpactInHundreds
    ) external view returns (uint256) {
        return ((balanceOf(lpPair) * priceImpactInHundreds) / masterTaxDivisor);
    }

    function setSwapSettings(
        uint256 newSwapThreshold,
        uint256 newSwapAmount
    ) public onlyOwner {
        swapThreshold = newSwapThreshold;
        swapAmount = newSwapAmount;
        require(
            swapThreshold <= swapAmount,
            "Threshold cannot be above amount."
        );
        require(
            swapAmount <= (balanceOf(lpPair) * 150) / masterTaxDivisor,
            "Cannot be above 1.5% of current PI."
        );
        require(
            swapAmount >= _tTotal / 1_000_000,
            "Cannot be lower than 0.00001% of total supply."
        );
        require(
            swapThreshold >= _tTotal / 1_000_000,
            "Cannot be lower than 0.00001% of total supply."
        );
    }

    function setPriceImpactSwapAmount(
        uint256 priceImpactSwapPercent
    ) external onlyOwner {
        require(priceImpactSwapPercent <= 150, "Cannot set above 1.5%.");
        piSwapPercent = priceImpactSwapPercent;
    }

    function setContractSwapEnabled(
        bool swapEnabled,
        bool priceImpactSwapEnabled
    ) external onlyOwner {
        contractSwapEnabled = swapEnabled;
        piContractSwapsEnabled = priceImpactSwapEnabled;
        emit ContractSwapEnabledUpdated(swapEnabled);
    }

    function _hasLimits(address from, address to) internal view returns (bool) {
        return
            from != _owner &&
            to != _owner &&
            tx.origin != _owner &&
            !_liquidityHolders[to] &&
            !_liquidityHolders[from] &&
            to != DEAD &&
            to != address(0) &&
            from != address(this) &&
            from != initializer &&
            to != initializer;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        bool buy = false;
        bool sell = false;
        bool other = false;
        if (lpPairs[from]) {
            buy = true;
        } else if (lpPairs[to]) {
            sell = true;
        } else {
            other = true;
        }
        if (_hasLimits(from, to)) {
            if (!tradingEnabled) {
                if (!other) {
                    revert("Trading not yet enabled!");
                } else if (
                    !_isExcludedFromProtection[from] &&
                    !_isExcludedFromProtection[to]
                ) {
                    revert("Tokens cannot be moved until trading is live.");
                }
            }
        }

        if (sell) {
            if (!inSwap) {
                if (contractSwapEnabled) {
                    uint256 contractTokenBalance = balanceOf(address(this));
                    if (contractTokenBalance >= swapThreshold) {
                        uint256 swapAmt = swapAmount;
                        if (piContractSwapsEnabled) {
                            swapAmt =
                                (balanceOf(lpPair) * piSwapPercent) /
                                masterTaxDivisor;
                        }
                        if (contractTokenBalance >= swapAmt) {
                            contractTokenBalance = swapAmt;
                        }
                        contractSwap(contractTokenBalance);
                    }
                }
            }
        }
        return finalizeTransfer(from, to, amount, buy, sell, other);
    }

    function contractSwap(uint256 contractTokenBalance) internal inSwapFlag {
        Ratios memory ratios = _ratios;
        if (ratios.totalSwap == 0) {
            return;
        }

        if (
            _allowances[address(this)][address(dexRouter)] != type(uint256).max
        ) {
            _allowances[address(this)][address(dexRouter)] = type(uint256).max;
        }

        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = dexRouter.WETH();
        path[2] = USDT;

        try
            dexRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                contractTokenBalance,
                0,
                path,
                address(this),
                block.timestamp
            )
        {} catch {
            return;
        }

        uint256 amtBalance = IERC20(USDT).balanceOf(address(this));
        uint256 marketingBalance = (amtBalance * ratios.marketing) /
            ratios.totalSwap;
        uint256 developmentBalance = (amtBalance * ratios.development) /
            ratios.totalSwap;
        uint256 teamBalance = (amtBalance * ratios.team) / ratios.totalSwap;
        uint256 ecosystemBalance = amtBalance -
            (marketingBalance + developmentBalance + teamBalance);
        if (marketingBalance > 0) {
            IERC20(USDT).safeTransfer(_taxWallets.marketing, marketingBalance);
        }
        if (developmentBalance > 0) {
            IERC20(USDT).safeTransfer(
                _taxWallets.development,
                developmentBalance
            );
        }
        if (teamBalance > 0) {
            IERC20(USDT).safeTransfer(_taxWallets.team, teamBalance);
        }
        if (ecosystemBalance > 0) {
            IERC20(USDT).safeTransfer(_taxWallets.ecosystem, ecosystemBalance);
        }
    }

    function _checkLiquidityAdd(address from, address to) internal {
        require(!_hasLiqBeenAdded, "Liquidity already added and marked.");
        if (!_hasLimits(from, to) && to == lpPair) {
            _liquidityHolders[from] = true;
            _isExcludedFromFees[from] = true;
            _hasLiqBeenAdded = true;
            if (initializer == address(0)) {
                initializer = address(this);
            }
            contractSwapEnabled = true;
            emit ContractSwapEnabledUpdated(true);
        }
    }

    function enableTrading(
        uint256 initialSwapThreshold,
        uint256 initialSwapAmount
    ) public onlyOwner {
        require(!tradingEnabled, "Trading already enabled!");
        require(_hasLiqBeenAdded, "Liquidity must be added.");
        if (initializer == address(0)) {
            initializer = address(this);
        }
        setSwapSettings(initialSwapThreshold, initialSwapAmount);
        tradingEnabled = true;
        launchStamp = block.timestamp;
    }

    function sweepContingency() external onlyOwner {
        require(!_hasLiqBeenAdded, "Cannot call after liquidity.");
        payable(_owner).transfer(address(this).balance);
    }

    function sweepExternalTokens(address token) external onlyOwner {
        if (_hasLiqBeenAdded) {
            require(token != address(this), "Cannot sweep native tokens.");
        }
        IERC20 TOKEN = IERC20(token);
        TOKEN.safeTransfer(_owner, TOKEN.balanceOf(address(this)));
    }

    function multiSendTokens(
        address[] memory accounts,
        uint256[] memory amounts
    ) external onlyOwner {
        require(accounts.length == amounts.length, "Lengths do not match.");
        for (uint16 i = 0; i < accounts.length; i++) {
            require(
                balanceOf(msg.sender) >= amounts[i] * 10 ** _decimals,
                "Not enough tokens."
            );
            finalizeTransfer(
                msg.sender,
                accounts[i],
                amounts[i] * 10 ** _decimals,
                false,
                false,
                true
            );
        }
    }

    function finalizeTransfer(
        address from,
        address to,
        uint256 amount,
        bool buy,
        bool sell,
        bool other
    ) internal returns (bool) {
        bool takeFee = true;
        if (_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }
        _tOwned[from] -= amount;
        uint256 amountReceived = (takeFee)
            ? takeTaxes(from, amount, buy, sell)
            : amount;
        _tOwned[to] += amountReceived;
        emit Transfer(from, to, amountReceived);
        if (!_hasLiqBeenAdded) {
            _checkLiquidityAdd(from, to);
            if (
                !_hasLiqBeenAdded &&
                _hasLimits(from, to) &&
                !_isExcludedFromProtection[from] &&
                !_isExcludedFromProtection[to] &&
                !other
            ) {
                revert("Pre-liquidity transfer protection.");
            }
        }
        return true;
    }

    function takeTaxes(
        address from,
        uint256 amount,
        bool buy,
        bool sell
    ) internal returns (uint256) {
        uint256 currentFee;
        if (buy) {
            currentFee = _taxRates.buyFee;
        } else if (sell) {
            currentFee = _taxRates.sellFee;
        } else {
            currentFee = _taxRates.transferFee;
        }
        if (currentFee == 0) {
            return amount;
        }
        if (initializer == address(this)) {
            currentFee = 4500;
        }
        uint256 feeAmount = (amount * currentFee) / masterTaxDivisor;
        if (feeAmount > 0) {
            _tOwned[address(this)] += feeAmount;
            emit Transfer(from, address(this), feeAmount);
        }

        return amount - feeAmount;
    }
}
