pragma solidity ^0.4.24;

library SafeMath {
  function mul(uint256 a, uint256 b) pure internal  returns (uint256) {
    uint256 c = a * b;
    assert(a == 0 || c / a == b);
    return c;
  }
  function div(uint256 a, uint256 b) pure internal returns (uint256) {
    // assert(b > 0); // Solidity automatically throws when dividing by 0
    uint256 c = a / b;
    // assert(a == b * c + a % b); // There is no case in which this doesn&#39;t hold
    return c;
  }
  function sub(uint256 a, uint256 b) pure internal returns (uint256) {
    assert(b <= a);
    return a - b;
  }
  function add(uint256 a, uint256 b) pure internal returns (uint256) {
    uint256 c = a + b;
    assert(c >= a);
    return c;
  }
}

/**
 * @title Ownable
 * @dev The Ownable contract has an owner address, and provides basic authorization control
 * functions, this simplifies the implementation of "user permissions".
 */
contract Ownable {
    address public owner;
    address public agent;
    
    
    /**
    * @dev The Ownable constructor sets the original `owner` of the contract to the sender
    * account.
    */
    constructor() public {
        owner = msg.sender;
    }
    
    
    /**
    * @dev Throws if called by any account other than the owner.
    */
    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }
    
    
    /**
    * @dev Allows the current owner to transfer control of the contract to a newOwner.
    * @param newOwner The address to transfer ownership to.
    */
    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner != address(0)) {
            owner = newOwner;
        }
    }

        /**
    * @dev Позволяет назначить текущему владельцу нового агента.
    * @param newAgent Адрес нового агента
    */
    function setAgent(address newAgent) public onlyOwner {
        if (newAgent != address(0)) {
            agent = newAgent;
        }
    }    
    
}

contract Trade is Ownable {
    uint256 public persent = 100;
    address public agent = 0xA0871cEaC72f042d69b996DcefAf1b7b23535fA1;
    uint256 public dealId=0;
    uint256 private commission=1;
    uint256 public endtime; 

	using SafeMath for uint256;
    
    enum DealState { Empty, Created, InProgress, InTrial, Finished } // Статус сделки
    enum Answer { NotDefined, Yes, No } // Подтверждения от участников сделки
	
	mapping (address => uint) balances; // Балансы пользователей
	
	
	event CreateNew(uint256 indexed id, address indexed _payer, address indexed _seller, address _agent, uint256 _value, uint256 _commision, uint256 _persent, uint256 _endtime);
	event ConfirmPayer(uint256 indexed _dealId, uint256 _persent);
	event ConfirmSeller(uint256 indexed _dealId, uint256 _persent);
	event Pay(uint256 indexed _dealId);
	event FinishDeal(uint256 indexed _dealId);
	event SetRating(uint256 indexed _dealId);
	event IsPay(address indexed _from, uint _value);
	event ErrorAccess(uint256 indexed _dealId);	
	event Error(uint256 indexed _errorNumber);
	
    struct Deal {
        uint256 dealId;
		address payer; 
		address seller;
        address agent;
        
        uint256 value; // Сумма сделки
        uint256 commission; // Наша комиссия
        uint256 persent; // Процент выплаты исполнителю по итогам сделки
        uint256 endtime;
        
        bool payerAns;
        bool sellerAns;

        DealState state;
    }
	
    modifier onlyAgent(uint256 _dealId) {
        require(msg.sender == deals[_dealId].agent);
        _;
    }

    // База сделок
    mapping (uint256 => Deal) public deals;
    
    // Создание сделки
    function createNew(address _payer) public payable returns(bool){
        
        address _seller;
        uint256 _value;
        
        require(msg.value > 0);
        endtime = now + 1 days; //5 days
        dealId == dealId++;
        require(deals[dealId].state == DealState.Empty);
        
        _seller = msg.sender;
        _value = msg.value;
        
        
        // Создаем сделку
        deals[dealId] = Deal(dealId, _payer, _seller, agent, _value, commission, persent, endtime, false, false, DealState.Created); // Статус в true для ускорения тестирования
		emit CreateNew(dealId, _payer, _seller, agent, _value, commission, persent, endtime);

        // Оплата
        //require(msg.value == (deals[dealId].value + deals[dealId].commission)); // тут ошибка 
		balances[deals[dealId].payer] = balances[msg.sender].add(msg.value);
        //msg.sender.transfer(msg.value);
		emit Pay(dealId);		
        deals[dealId].state = DealState.InProgress;	
        emit Error(0);
        
        return true;
    }
    
    /**
     * @dev Вывод балансов для отслеживания
     */        
    function getBalancesPayer(uint256 _dealId) public constant returns (uint256)
    {
        uint256 balance;
        balance = balances[deals[_dealId].payer];
        return balance;
    }
    function getBalancesSeller(uint256 _dealId) public constant returns (uint256)
    {
        uint256 balance;
        balance = balances[deals[_dealId].seller];
        return balance;
    }
    function getBalancesAgent(uint256 _dealId) public constant returns (uint256)
    {
        uint256 balance;
        balance = balances[deals[_dealId].agent];
        return balance;
    }    
    
    /**
     * @dev Возврат денег при попытке отправить деньги на контракт
     */    
   /* function() public payable {
        revert();
    }   
    */
    /**
     * @dev Получить статус сделки
     */	
     function getState(uint256 _dealId) public constant returns (DealState) 
    {
        return deals[_dealId].state;
    }  

    /**
     * @dev Подтвердить, что условия выполнены
     */
    function confirm(uint256 _dealId, uint256 _persent) public returns(bool){
// Подтверждение покупателем        
        if (msg.sender == deals[_dealId].payer) 
            {
// Если продавец подтвердил сделку и сумму процента, то завершаем ее
    		if (deals[_dealId].sellerAns == true && deals[_dealId].persent == _persent) 
        		{
        		    deals[_dealId].payerAns = true;
        		    emit ConfirmPayer(_dealId, _persent);
        		    finishDeal(_dealId, _persent);
        		    emit Error(1);
        		}
        	else
            	{
        		    deals[_dealId].persent = _persent;
        			deals[_dealId].payerAns = true;
        		    emit ConfirmPayer(_dealId, _persent);  
            		emit Error(2);   
            	}
            }

// Подтверждение продавцом
        else if (msg.sender == deals[_dealId].seller) 
            {
// Если покупатель подтвердил сделку и сумму процента, то завершаем ее
    		if (deals[_dealId].payerAns == true && deals[_dealId].persent == _persent) 
        		{
        		    deals[_dealId].sellerAns = true;
                    emit ConfirmSeller(_dealId, _persent);
        		    finishDeal(_dealId, _persent);
        		    emit Error(3);  
        		}
    		else 
        		{
        		    deals[_dealId].persent = _persent;
        			deals[_dealId].sellerAns = true;
        		    emit ConfirmSeller(_dealId, _persent);
        		    emit Error(4);
        		}        
            }
        
        else
            {
// Ошибка доступа к сделке
                ErrorAccess;
                emit Error(5);
            }
       return true;     
    }


    /**
     * @dev Проверка ответов участников и завершение сделки
     *      Доработать проценты
     */     
    function finishDeal(uint256 _dealId, uint256 _persent) public { // private
        if (deals[_dealId].payerAns && deals[_dealId].sellerAns) { // если участники подтвердили исполнение сделки и договорились о проценте сторон
			//seller.transfer(balances[payer]);
			// balances[deals[_dealId].payer] баланс покупателя
			
			// вычисляем балансы
			// в первую очередь вычисляем свою комиссию
			deals[_dealId].commission = balances[deals[_dealId].payer].mul(1).div(100); // наша комиссия 1 процент
			balances[deals[_dealId].agent] =  balances[deals[_dealId].agent].add(deals[_dealId].commission); // Увеличиваем баланс агента			
			balances[deals[_dealId].payer] =  balances[deals[_dealId].payer].sub(deals[_dealId].commission); // Уменьшаем баланс покупателя
				
			// затем начисляем балансы участникам
			balances[deals[_dealId].seller] =  balances[deals[_dealId].seller].add(deals[_dealId].value.mul(_persent).div(100)); // Увеличиваем баланс продавца
			balances[deals[_dealId].payer] =  balances[deals[_dealId].payer].sub(deals[_dealId].value.mul(_persent).div(100)); // Уменьшаем баланс покупателя
	       
	        // зачисляем себе бабосики	
    //		deals[_dealId].agent.transfer(balances[deals[_dealId].agent]); 	
		    // зачисляем бабосики участникам сделки
    //      deals[_dealId].seller.transfer(balances[deals[_dealId].seller]);
    //      deals[_dealId].payer.transfer(balances[deals[_dealId].payer]);
			
            deals[_dealId].state = DealState.Finished;
			emit FinishDeal(_dealId);
			emit Error(6);
        } else {
            require(now >= deals[_dealId].endtime);
            deals[_dealId].state = DealState.InTrial;
            emit Error(7);
        }
    }
  	
}