// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import {IERC20} from "./IERC20.sol";
import {IUniswapV2Router01} from "./IUniswapV2Router01.sol";

contract DiamondHands {

    struct Order {
        address inputToken;
        uint inputAmount;
        address outputToken;
        uint minOutputAmount;
        uint deadline;
        uint feePercent;
        bool completed;
    }

    event OrderCreated(
        address indexed from,
        address indexed inputToken,
        uint indexed index,
        uint inputAmount,
        address outputToken,
        uint minOutputAmount,
        uint deadline,
        uint feePercent
    );

    event OrderCompleted(
        address indexed from,
        address indexed inputToken,
        uint indexed index,
        address uniswapRouter,
        address[] path,
        uint actualOutputAmount,
        uint actualReceivedAmount,
        address receivedToken
    );

    event UpdateFeePercent(
        uint oldValue,
        uint newValue
    );

    event UpdateFeePool(
        address oldAddress,
        address newAddress
    );

    uint constant MAX_UINT = 2 ^ 256 - 1;
    uint constant ONE_HUNDRED_PERCENT = 100 ether;
    // 1%
    uint constant MAX_FEE_PERCENT = 1 ether;
    // 100%
    address feePoolAddress;
    // actual feePercent = feePercent / 1e18
    uint feePercent;
    // owner => orders
    mapping(address => Order[]) orderBook;
    mapping(address => bool) supportedSwapRouters;
    address owner;
    /**
    /* When closed equals true, every order can withdraw regardless output amount condition.
    /* It can be set to true only once then can not be set to false.
    /* We use it to make sure that in emergency case, all people can receive their tokens.
    */
    bool closed;

    constructor(address[] memory _supportedSwapRouters){
        require(_supportedSwapRouters.length > 0, "_supportedSwapRouters must be not empty!");
        owner = msg.sender;
        feePoolAddress = msg.sender;
        feePercent = 0 wei;
        closed = false;
        for (uint i = 0; i < _supportedSwapRouters.length; i++) {
            supportedSwapRouters[_supportedSwapRouters[i]] = true;
        }
    }

    modifier ownerOnly() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    function changeOwner(address _newOwner) ownerOnly public {
        owner = _newOwner;
    }

    // Return order index
    function deposit(address _inputToken, uint _amount, address _outputToken, uint _minOutputAmount, uint _deadline) public returns (uint) {
        require(!closed, "This app has been closed!");
        require(_amount > 0, "Amount must be greater than 0!");
        IERC20 inputToken = IERC20(_inputToken);
        require(inputToken.balanceOf(msg.sender) > _amount, "Insufficient balance!");
        require(inputToken.allowance(msg.sender, address(this)) > _amount, "Insufficient allowance!");
        require(inputToken.transferFrom(msg.sender, address(this), _amount), "Unable to deposit token!");

        Order[] storage orders = orderBook[msg.sender];
        require(orders.length < MAX_UINT - 1, "Can not create more orders!");
        orders.push(Order(_inputToken, _amount, _outputToken, _minOutputAmount, _deadline, feePercent, false));
        emit OrderCreated(msg.sender, _inputToken, orders.length - 1, _amount, _outputToken, _minOutputAmount, _deadline, feePercent);
        return orders.length - 1;
    }

    function getDepositedAmount(address _from, uint _index) view public returns (uint){
        Order memory order = _getOrderM(_from, _index);
        return order.inputAmount;
    }

    function withdraw(address _uniswapRouter, address[] memory _path, uint _index) public {
        require(supportedSwapRouters[_uniswapRouter], "Router is not supported!");
        Order storage order = _getOrderS(msg.sender, _index);
        require(_path[0] == order.inputToken, "The first path must be input token");
        require(_path[_path.length - 1] == order.outputToken, "The last path must be output token");
        require(order.completed == false, "This order has been withdrawn!");
        // Set order.completed to true ASAP to prevent reentrancy vulnerability
        order.completed = true;

        // Check withdrawable
        uint[] memory amounts = IUniswapV2Router01(_uniswapRouter).getAmountsOut(order.inputAmount, _path);
        uint actualOutputAmount = amounts[1];
        if (!closed) require(actualOutputAmount >= order.minOutputAmount, "Actual output amount is less than min output amount!");

        // Transfer
        uint poolFeeAmount = order.inputAmount * order.feePercent / ONE_HUNDRED_PERCENT;
        uint actualReceivedAmount = order.inputAmount - poolFeeAmount;
        require(IERC20(order.inputToken).approve(address(this), order.inputAmount), "Failed to approve input token!");
        require(
            IERC20(order.inputToken).transferFrom(address(this), msg.sender, actualReceivedAmount),
            "Failed to transfer from contract to sender"
        );
        require(
            IERC20(order.inputToken).transferFrom(address(this), feePoolAddress, poolFeeAmount),
            "Failed to transfer pool fee"
        );

        emit OrderCompleted(
            msg.sender,
            order.inputToken,
            _index,
            _uniswapRouter,
            _path,
            actualOutputAmount,
            actualReceivedAmount,
            order.inputToken
        );
    }

    function swapThenWithdraw(address _uniswapRouter, address[] memory _path, uint _index, uint _deadline) public {
        require(supportedSwapRouters[_uniswapRouter], "Router is not supported!");
        Order storage order = _getOrderS(msg.sender, _index);
        require(_path[0] == order.inputToken, "The first path must be input token");
        require(_path[_path.length - 1] == order.outputToken, "The last path must be output token");
        require(order.completed == false, "This order has been withdrawn!");
        // Set order.completed to true ASAP to prevent reentrancy vulnerability
        order.completed = true;

        uint poolFeeAmount = order.minOutputAmount * feePercent / ONE_HUNDRED_PERCENT;
        uint minOutputAmount = order.minOutputAmount + poolFeeAmount;

        uint actualOutputAmount = getActualOutputAmount(_uniswapRouter, _path, order.inputAmount);
        if (!closed) require(actualOutputAmount - poolFeeAmount >= order.minOutputAmount, "Actual output amount is less than min output amount!");

        require(IERC20(order.inputToken).approve(_uniswapRouter, order.inputAmount), "Unable to approve input token!");
        uint actualReceivedAmount;
        if (poolFeeAmount == 0) {
            uint[] memory amounts = IUniswapV2Router01(_uniswapRouter).swapExactTokensForTokens(
                order.inputAmount,
                minOutputAmount,
                _path,
                msg.sender,
                _deadline
            );
            actualReceivedAmount = amounts[1];
        } else {
            /**
            /* If transfer to sender directly, sender will have to approve outputToken to transfer pool fee back.
            /* Therefore, we will swap output token to contract, then transfer output to sender.
            */
            uint[] memory amounts = IUniswapV2Router01(_uniswapRouter).swapExactTokensForTokens(
                order.inputAmount,
                minOutputAmount,
                _path,
                address(this),
                _deadline
            );
            actualReceivedAmount = amounts[1] - poolFeeAmount;
            require(
                IERC20(order.outputToken).approve(address(this), amounts[1]),
                "Failed to approve output token!"
            );
            require(
                IERC20(order.outputToken).transferFrom(address(this), msg.sender, actualReceivedAmount),
                "Failed to transfer output token msg.sender"
            );
            require(
                IERC20(order.outputToken).transferFrom(address(this), feePoolAddress, poolFeeAmount),
                "Failed to transfer pool fee"
            );
        }

        emit OrderCompleted(
            msg.sender,
            order.inputToken,
            _index,
            _uniswapRouter,
            _path,
            actualOutputAmount,
            actualReceivedAmount,
            order.outputToken
        );

        order.completed = true;
    }

    function getActualOutputAmount(
        address _uniswapRouter,
        address[] memory _path,
        uint _inputAmount
    ) view public returns (uint256){
        require(supportedSwapRouters[_uniswapRouter], "This swap router is not supported!");
        uint[] memory amounts = IUniswapV2Router01(_uniswapRouter).getAmountsOut(_inputAmount, _path);
        return amounts[1];
    }

    function orderCompleted(address _from, uint _index) view public returns (bool){
        Order memory order = _getOrderM(_from, _index);
        return order.completed;
    }

    function getCurrentFeePercentInWei() view public returns (uint){
        return feePercent;
    }

    function maxFeePercentInWei() pure public returns (uint){
        return MAX_FEE_PERCENT;
    }

    function calculatePoolFee(address _from, uint _index) view public returns (uint){
        Order memory order = _getOrderM(_from, _index);
        return order.minOutputAmount * feePercent / ONE_HUNDRED_PERCENT;
    }

    function updateFeePool(address _newAddress) ownerOnly public {
        emit UpdateFeePool(feePoolAddress, _newAddress);
        feePoolAddress = _newAddress;
    }

    //feePercent must be in the range [0, MAX_FEE_PERCENT]
    function updateFeePercentInWei(uint _newFeePercentInWei) ownerOnly public {
        require(_newFeePercentInWei <= MAX_FEE_PERCENT, "Fee percent must be less than or equals to MAX_FEE_PERCENT");
        emit UpdateFeePercent(feePercent, _newFeePercentInWei);
        feePercent = _newFeePercentInWei;
    }

    // This function can be called only once, then closed variable can not be set to false.
    function closeApp() ownerOnly public {
        closed = true;
    }

    function _getOrderM(address _from, uint _index) view private returns (Order memory){
        Order memory order = orderBook[_from][_index];
        return order;
    }

    function _getOrderS(address _from, uint _index) view private returns (Order storage){
        Order storage order = orderBook[_from][_index];
        return order;
    }

    function countOrders(address _from) view public returns (uint){
        return orderBook[_from].length;
    }

    function getOrders(address _from, uint _indexFrom, uint _indexTo) view public returns (Order[] memory){
        Order[] memory orderList = orderBook[_from];
        if (orderList.length == 0) {
            return orderList;
        }
        uint maxIndex = orderList.length - 1;
        if (_indexTo > maxIndex) {
            _indexTo = maxIndex;
        }
        uint size = _indexTo - _indexFrom + 1;
        Order[] memory orders = new Order[](size);
        for (uint i = _indexFrom; i <= _indexTo; i++) {
            orders[i - _indexFrom] = orderList[i];
        }
        return orders;
    }

    function isSupportedSwapRouter(address _router) view public returns (bool){
        return supportedSwapRouters[_router];
    }
}
