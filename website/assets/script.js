
// State to track current currency mode (default BDT)
let currentCurrency = 'BDT';
const prices = {
    BDT: {
        mobile: 3500,
        pc: 7500
    },
    USD: {
        mobile: 50,
        pc: 200
    }
};

// Switch Pricing Tabs
function switchPricing(region) {
    // Update Tabs
    document.querySelectorAll('.tab-btn').forEach(btn => btn.classList.remove('active'));
    document.querySelector(`.tab-btn[onclick="switchPricing('${region}')"]`).classList.add('active');

    // Update Pricing Containers
    document.querySelectorAll('.pricing-container').forEach(container => {
        container.classList.remove('active');
        container.style.display = "none"; // Ensure hidden immediately
    });

    const activeContainer = document.getElementById(`pricing-${region}`);
    activeContainer.style.display = "flex";
    // Small delay to allow display flex to apply before opacity transition
    setTimeout(() => activeContainer.classList.add('active'), 10);

    // Update Currency State
    currentCurrency = (region === 'bd' || region === 'default') ? 'BDT' : 'USD';
    updateTotal(); // Update form total if it's visible
}

// Select Package from Pricing Card (Scrolls to form and sets values)
function selectPackage(type, price) {
    const packageSelect = document.getElementById('packageSelect');

    // Set dropdown value
    packageSelect.value = type;

    // Update Total Immediately
    updateTotal();

    // Smooth scroll to order section handled by anchor tag href="#order-now" in HTML
}

// Update Total Price in Order Form
function updateTotal() {
    const packageType = document.getElementById('packageSelect').value;
    const totalDisplay = document.getElementById('totalDisplay');

    let price = 0;

    if (currentCurrency === 'BDT') {
        price = prices.BDT[packageType];
        totalDisplay.innerText = `৳${price.toLocaleString()}`;
    } else {
        price = prices.USD[packageType];
        totalDisplay.innerText = `$${price}`;
    }
}

// Form Submission (Mock)
document.getElementById('orderForm').addEventListener('submit', function (e) {
    e.preventDefault();

    const btn = document.querySelector('.btn-confirm');
    const originalText = btn.innerText;

    btn.innerText = 'Processing...';
    btn.style.opacity = '0.7';

    setTimeout(() => {
        alert(`Order Placed Successfully!\n\nTotal: ${document.getElementById('totalDisplay').innerText}\n(This is a demo submission)`);
        btn.innerText = originalText;
        btn.style.opacity = '1';
        this.reset();
        updateTotal();
    }, 1500);
});

// Initialize
document.addEventListener('DOMContentLoaded', () => {
    // Determine default based on some logic if needed, currently defaults to BD as per HTML structure
    updateTotal();
});

// Optional: Language Switcher Interaction
document.querySelector('.language-switcher').addEventListener('click', (e) => {
    if (e.target.tagName === 'SPAN' && !e.target.classList.contains('active')) {
        document.querySelectorAll('.language-switcher span').forEach(el => el.classList.remove('active'));
        e.target.classList.add('active');
        // Here you would implement actual language translation logic
        alert('Language switch feature would be implemented here (e.g. i18next).');
    }
});
