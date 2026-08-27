//var years  = [[74, [1, 3]], [75, [4, 19]], [76, [20, 29]], [77, [30, 41]], [78, [42, 53]], [79, [54, 78]], [80, [79, 104]], [81, [105, 130]], [82, [131, 154]], [83, [155, 171]], [84, [172, 183]], [85, [184, 194]]];
//var numbers = [[1,52],[2,52],[3,52],[4,32],[5,52],[6,52],[7,52],[8,52],[9,0],[10,52],[11,52],[12,52],[13,52],[14,80],[15,80],[16,80],[17,80],[18,80],[19,80],[20,80],[21,80],[22,80],[23,76],[24,0],[25,76],[26,76],[27,80],[28,80],[29,80],[30,80],[31,80],[32,80],[33,80],[34,80],[35,80],[36,75],[37,80],[38,80],[39,80],[40,80],[41,80],[42,80],[43,80],[44,80],[45,80],[46,80],[47,80],[48,80],[49,80],[50,80],[51,80],[52,80],[53,80],[54,52],[55,52],[56,52],[57,52],[58,52],[59,52],[60,52],[61,52],[62,52],[63,52],[64,52],[65,52],[66,52],[67,52],[68,52],[69,52],[70,52],[71,52],[72,52],[73,52],[74,52],[75,52],[76,52],[77,52],[78,52],[79,52],[80,52],[81,68],[82,68],[83,68],[84,68],[85,68],[86,68],[87,68],[88,68],[89,68],[90,68],[91,68],[92,68],[93,68],[94,68],[95,68],[96,68],[97,68],[98,68],[99,68],[100,84],[101,100],[102,100],[103,100],[104,100],[105,100],[106,100],[107,84],[108,84],[109,84],[110,84],[111,84],[112,84],[113,82],[114,82],[115,84],[116,68],[117,68],[118,68],[119,72],[120,68],[121,68],[122,68],[123,68],[124,68],[125,68],[126,68],[127,68],[128,68],[129,68],[130,68],[131,70],[132,68],[133,68],[134,68],[135,68],[136,68],[137,68],[138,68],[139,68],[140,68],[141,68],[142,68],[143,68],[144,68],[145,68],[146,68],[147,68],[148,68],[149,68],[150,68],[151,68],[152,68],[153,52],[154,52],[155,52],[156,52],[157,16,1],[158,16,1],[159,16,1],[160,16,1],[161,16,1],[162,16,1],[163,16,1],[164,16,1],[165,16,1],[166,16,1],[167,16,1],[168,16,1],[169,16,1],[170,16,1],[171,16,1],[172,0],[173,52],[174,52],[175,52],[176,52],[177,0],[178,52],[179,52],[180,52],[181,50],[182,52],[183,0],[184,0],[185,52],[186,0],[187,0],[188,0],[189,0],[190,68,2],[191,0],[192,52],[193,50],[194,52]];

var years = [[1, [155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166]], [2, [145, 140, 141, 142, 147]], [3, [146, 152]], [4, [154, 149, 144, 151, 153, 150]]];
//var numbers = [[140, [1,84]], [141, [1,84]], [142, [3,83]], [144, [1,84]], [145, [1,84]], [146, [1,52]], [147, [1,84]], [149, [1,84]], [150, [1,84]], [151, [1,84]], [152, [1,68]], [153, [1,84]], [154, [1,136]], [155, [1,68]], [156, [1,100]], [157, [1,68]], [158, [1,68]], [159, [1,68]], [160, [1,76]], [161, [1,76]], [162, [1,92]], [163, [1,92]], [164, [1,92]], [165, [1,92]], [166, [1,92]]];
var numbers = {140:[1,84,"2 - Okt '90."], 141:[1,84,"3 - Dec '90."], 142:[3,83,"4 / 5 - Jan-Feb '91.",4], 144:[1,84,"2 - Jun '94."], 145:[1,84,"1 - Sep '90."], 146:[1,52,"1 - Okt '92."], 147:[1,84,"6 / 7 / 8 - Mar-Maj '91."], 149:[1,84,"1 - Maj '94.",3], 150:[1,84,"5 - Jun '95.",3], 151:[1,84,"3 - Sep '94."], 152:[1,68,"2 - Dec '92."], 153:[1,84,"4 - Nov '94."], 154:[1,136,"Godišnjak '93.",2], 155:[1,68,"1 - Feb '89.",1], 156:[1,100,"2 - Mar '89.", 1], 157:[1,68,"3 - Apr '89."], 158:[1,68,"4 - Maj '89."], 159:[1,68,"5 - Jun '89."], 160:[1,76,"6 / 7 - Jul-Avg '89."], 161:[1,76,"8 - Okt '89."], 162:[1,92,"9 - Nov '89."], 163:[1,92,"10 / 11 - Dec '89-Jan '90.",5], 164:[1,92,"12 - Mar '90.",6], 165:[1,92,"13 - Apr '90.",7], 166:[1,92,"14 - Jun '90.",8]};
console.log(numbers[140][2]);

var combinedYears = [155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166, 145, 140, 141, 142, 147, 146, 152, 154, 149, 144, 151, 153, 150];

// default tile sizes

var regularTile = [256, 256];
var rightTile   = [176, 256];
var bottomTile  = [256, 161];
var cornerTile  = [176, 161];

var issue = 0;
var page = 0;

var zoomLevel = 100;
var selectedYear = 2;
var yearsScroll = 0;

var storageWorks = false;

var w = window.innerWidth || document.documentElement.clientWidth || document.body.clientWidth;
var h = window.innerHeight || document.documentElement.clientHeight || document.body.clientHeight;

function storageAvailable(type) {
    var storage;
    try {
        storage = window[type];
        var x = '__storage_test__';
        storage.setItem(x, x);
        storage.removeItem(x);
        return true;
    }
    catch(e) {
        return e instanceof DOMException && (
            e.code === 22 ||
            e.code === 1014 ||
            e.name === 'QuotaExceededError' ||
            e.name === 'NS_ERROR_DOM_QUOTA_REACHED') &&
            (storage && storage.length !== 0);
    }
}

window.onresize = function () {
    w = window.innerWidth || document.documentElement.clientWidth || document.body.clientWidth;
    h = window.innerHeight || document.documentElement.clientHeight || document.body.clientHeight;
    var offsetY = (window.pageYOffset !== undefined) ? window.pageYOffset : (document.documentElement || document.body.parentNode || document.body).scrollTop;
    var container = document.getElementById("tilesContainer");
    if (container != null) {
        var containerWidth = container.offsetWidth;
        if (containerWidth > w) {
            var leftMargin = Math.round((containerWidth - w) / 2);
            window.scroll(leftMargin, offsetY);
        } else container.style.margin = "0 auto";
    }
}

window.onload = function () {
    storageWorks = storageAvailable('localStorage');
    if (storageWorks) {
        if (!localStorage.getItem('zoom')) {
            try {
                localStorage.setItem('zoom', 100);
            }
            catch (e) {
                console.log(e);
            }
        } else {
            zoomLevel = parseInt(localStorage.getItem('zoom'));
        }
    }
    var qmPos = window.document.URL.indexOf('?');
    if (qmPos != -1) {
        qstring = window.document.URL.substring(qmPos+1);
        try {
            var decodedqs = decodeURIComponent(qstring);
            var paramsArray = decodedqs.split('&');
            var parsedParams = [];
            for (var i = 0; i < paramsArray.length; i++) {
                parsedParams.push(paramsArray[i].split('='));
            }
            for (var i = 0; i < parsedParams.length; i++) {
                if ((parsedParams[i][0] === "iss") && (parsedParams[i][1])) 
                    if (!isNaN(parseInt(parsedParams[i][1], 10))) issue = parseInt(parsedParams[i][1], 10);
                if ((parsedParams[i][0] === "pg") && (parsedParams[i][1])) 
                    if (!isNaN(parseInt(parsedParams[i][1], 10))) page = parseInt(parsedParams[i][1], 10);
            }
	    var issueExists = false;
	    for (i = 0; i < combinedYears.length; i++) {
	    	if (issue == combinedYears[i]) {
			issueExists = true;
			break;
		}
	    }
	    if (issueExists) {
	    	if ((page >= numbers[issue][0]) && (page <= numbers[issue][1])) {
	                renderPage();
		} else {
			showYears();
		}
            } else {
                showYears();
            }
        } catch(e) {
            console.error(e);
            showYears();
        }
    } else showYears();
}

function showYears() {
    var mainContainer = document.getElementById("mainContainer");
    if (mainContainer) document.body.removeChild(mainContainer);

    var yearsContainer = document.createElement("div");
    yearsContainer.id = "yearsContainer";
    yearsContainer.className = "container";
    document.body.insertBefore(yearsContainer, document.getElementById("footer"));

    var logo = document.createElement("div");
    logo.className = "logo";
    var logoImg = document.createElement("img");
    logoImg.className = "logoImg";
    logoImg.src = "assets/logo.png";
    logo.appendChild(logoImg);
    var underLogo = document.createElement("p");
    var underLogoTxt = document.createTextNode("Ritam arhiva 1989-1995.");
    underLogo.appendChild(underLogoTxt);
    logo.appendChild(underLogo);
    yearsContainer.appendChild(logo);
    for (var i = 0; i < years.length; i++) {
        var issuesContainer = document.createElement("div");
        issuesContainer.id = "yearContainer_" + (i+1);
        yearsContainer.appendChild(issuesContainer);
        var issuesYear = document.createElement("div");
        var yearTxt = document.createTextNode("Serija " + years[i][0]);
        issuesYear.className = "yearTitle";
        issuesYear.id = "yearTitle_" + (i+1);
        issuesYear.appendChild(yearTxt);
        issuesYear.onclick = function () { toggleYear(this.id); };
        issuesContainer.appendChild(issuesYear);
    }
    openYear(selectedYear);
}

function toggleYear(yearId) {
    var yearNo = parseInt(yearId.substring(yearId.indexOf('_')+1), 10);
    var issuesContainer = document.getElementById("yearContainer_" + selectedYear);
    var loadingIndicator = document.getElementById("loadingIndicator_" + selectedYear);
    var issuesImages = document.getElementById("yearImages_" + selectedYear);
    if (selectedYear != 0) {
        //setInterval
        if (loadingIndicator)
            if (loadingIndicator.parentNode) loadingIndicator.parentNode.removeChild(loadingIndicator);
        issuesContainer.removeChild(issuesImages);
    }
    if (yearNo == selectedYear) {
        selectedYear = 0;
    } else {
        selectedYear = yearNo;
        openYear(yearNo);
    }
}

function openYear(yearId) {
    var issuesContainer = document.getElementById("yearContainer_" + yearId);
    issuesContainer.scrollIntoView();
    var titleContainer = document.getElementById("yearTitle_" + yearId);
    var issuesImages = document.createElement("div");
    issuesImages.id = "yearImages_" + yearId;
    issuesImages.className = 'issuesImages';
    issuesContainer.appendChild(issuesImages);
    var totalIssues = years[yearId - 1][1].length;
    var loader = { loaded: 0, total: 0, indicator: null, indparent: null };
    loader.total = totalIssues;
    var loadingIndicator = document.createElement("div");
    loadingIndicator.id = "loadingIndicator_" + yearId;
    loadingIndicator.style.float = "right";
    loader.indicator = loadingIndicator;
    loader.indparent = titleContainer;
    titleContainer.appendChild(loadingIndicator);
    for (var j = 0; j < years[yearId-1][1].length; j++) {
        var issueDiv = document.createElement("div");
        issueDiv.className = "issuebox";
        var issueImg = document.createElement("img");
        issueImg.src = "/ritam/images/" + years[yearId-1][1][j] + "/1/icon.jpg";
        issueImg.id = "iss_" + years[yearId-1][1][j];
        issueImg.loader = loader;
        issueImg.yearId = yearId;
        issueImg.className = "issue";
        issueImg.onclick = function () { 
            yearsScroll = window.scrollY || window.pageYOffset;
            window.scroll(0, 0);
            openissue(this.id);
        }; 
        issueImg.onmouseover = function () { 
            this.style.cursor = "pointer";
            this.style.filter = 'brightness(140%)';
        }
        issueImg.onmouseout = function () { 
            this.style.cursor = "default";
            this.style.filter = 'brightness(1)';
        }
        issueImg.onload = function () {
            this.loader.loaded++;
            var loadingIndicator = document.getElementById("loadingIndicator_" + this.yearId);
            if (loadingIndicator) {
                loadingIndicator.innerHTML = "Loaded " + this.loader.loaded + " of " + this.loader.total;
                if (this.loader.loaded == this.loader.total) {
                    if (loadingIndicator.parentNode) loadingIndicator.parentNode.removeChild(loadingIndicator);
                }
            }
        }
        var issueNo = document.createElement("p");
        var issueNoSpan = document.createElement("span");
        var issueNoTxt = document.createTextNode(" " + numbers[years[yearId-1][1][j]][2] + " "); //
        issueNoSpan.appendChild(issueNoTxt);
        issueNo.appendChild(issueNoSpan);
        issueDiv.appendChild(issueImg);
        issueDiv.appendChild(issueNo);
        issuesImages.appendChild(issueDiv);
    }
}


function openissue(iss) {
    issue = parseInt(iss.substring(iss.indexOf('_')+1), 10);
    page = numbers[issue][0];
    // tile sizes override
    if (numbers[issue][3] !== undefined) {
        switch (numbers[issue][3]) {
            case 8: 
                    bottomTile  = [256, 199];
                    cornerTile  = [176, 199];
                    break;
            case 7:
                    bottomTile  = [256, 187];
                    cornerTile  = [176, 187];
                    break;
            case 6:
                    bottomTile  = [256, 218];
                    cornerTile  = [176, 218];
                    break;
            case 5:
                    bottomTile  = [256, 221];
                    cornerTile  = [176, 221];
                    break;
            case 4:
                    bottomTile  = [256, 205];
                    cornerTile  = [176, 205];
                    break;
            case 3:
                    bottomTile  = [256, 163];
                    cornerTile  = [176, 163];
                    break;
            case 2:
                    bottomTile  = [256, 173];
                    cornerTile  = [176, 173];
                    break;
            case 1:
                    bottomTile  = [256, 256];
                    cornerTile  = [176, 256];
                    break;
            default:
                    bottomTile  = [256, 161];
                    cornerTile  = [176, 161];
                    break;
        }
    } else {
        bottomTile  = [256, 161];
        cornerTile  = [176, 161];
    }
    renderPage();
}

function prev() {
    page--;
    renderPage();
}

function next() {
    page++;
    renderPage();
}

function jump() {
    page = document.getElementById("pageselect").value;
    renderPage();
}

function zoom(inout) {
    var w = window.innerWidth || document.documentElement.clientWidth;
    var h = window.innerHeight || document.documentElement.clientHeight;
    var container = document.getElementById("tilesContainer");
    if (!container) return;

    if (inout > 0) {
        if (zoomLevel < 200) zoomLevel += 10; else return;
    } else {
        if (zoomLevel > 20) zoomLevel -= 10; else return;
    }
    if (storageWorks) {
        try {
            localStorage.setItem('zoom', zoomLevel);
        }
        catch (e) {
            console.log(e);
        }
    }
    var oldStatusSpan = document.getElementById("statustxt");
    if (oldStatusSpan) {
        var statusDiv = oldStatusSpan.parentNode;
        var newStatusSpan = document.createElement("span");
        newStatusSpan.id = "statustxt";
        var newStatusTxt = document.createTextNode("Ritam broj " + numbers[issue][2] + ", strana " + page + " (" + zoomLevel + "%)");
        newStatusSpan.appendChild(newStatusTxt);
        statusDiv.replaceChild(newStatusSpan, oldStatusSpan);
    }

    var zoomIn = document.getElementById("zoomin");
    var zoomOut = document.getElementById("zoomout");
    if (zoomLevel == 200) {
        zoomIn.style.backgroundColor = "#999999";
        zoomIn.style.cursor = "default";
    } else {
        zoomIn.style.backgroundColor = "#ffffff";
        zoomIn.style.cursor = "pointer";
    }
    if (zoomLevel == 20) {
        zoomOut.style.backgroundColor = "#999999";
        zoomOut.style.cursor = "default";
    } else {
        zoomOut.style.backgroundColor = "#ffffff";
        zoomOut.style.cursor = "pointer";
    }

    var factor = zoomLevel / 100;

    var offsetX = (window.pageXOffset !== undefined) ? window.pageXOffset : (document.documentElement || document.body.parentNode || document.body).scrollLeft;
    var offsetY = (window.pageYOffset !== undefined) ? window.pageYOffset : (document.documentElement || document.body.parentNode || document.body).scrollTop;
    
    var oldWidth = container.offsetWidth;
    var oldHeight = container.offsetHeight;

    var containerWidth = (((regularTile[0] * 4) + rightTile[0]) * factor);
    container.style.width = "" + containerWidth + "px";
    var containerHeight = (((regularTile[1] * 6) + bottomTile[1]) * factor) + document.getElementById("topPad").offsetHeight;
    container.style.height = "" + containerHeight + "px";

    var leftMargin = 0;
    var topMargin  = 0;
    if (containerWidth > w) {
        if (oldWidth <= w) leftMargin = Math.round((containerWidth - w) / 2); else leftMargin = Math.round((offsetX * (containerWidth - w)) / (oldWidth - w));
    } else if (containerWidth < w) {
        leftMargin = Math.round((w - containerWidth) / 2);
    }
    if (offsetY > 0) topMargin = Math.round((offsetY * (containerHeight - h)) / (oldHeight - h));

    for (var v = 0; v <= 6; v++) {
        for (var h = 0; h <= 4; h++) {
            tileImg = document.getElementById("tile_" + (v*5+h+1));
            if ((h == 4) && (v <= 5)) {
                tileImg.width  = rightTile[0] * factor;
                tileImg.height = rightTile[1] * factor;
            } else if ((h == 4) && (v == 6)) {
                tileImg.width  = cornerTile[0] * factor;
                tileImg.height = cornerTile[1] * factor;
            } else if ((h < 4) && (v == 6)) {
                tileImg.width  = bottomTile[0] * factor;
                tileImg.height = bottomTile[1] * factor;
            } else {
                tileImg.width  = regularTile[0] * factor;
                tileImg.height = regularTile[1] * factor;
            }
        }
    }
    window.scroll(leftMargin, topMargin);
}

function createButton(buttonParent, id, className, imgSrc, w, h) {
    var newButton = document.createElement("button");
    newButton.id = id;
    newButton.className = className;
    var newButtonImg = document.createElement("img");
    newButtonImg.src = imgSrc;
    newButtonImg.width = w;
    newButtonImg.height = h;
    newButton.appendChild(newButtonImg);
    buttonParent.appendChild(newButton);
    return newButton;
}

function renderPage() {
    var yearsContainer = document.getElementById("yearsContainer");
    if (yearsContainer) document.body.removeChild(yearsContainer);
    if (document.getElementById("mainContainer")) document.body.removeChild(document.getElementById("mainContainer"));
    var mainContainer = document.createElement("div");
    mainContainer.id = "mainContainer";
    mainContainer.style.textAlign = "center";
    document.body.insertBefore(mainContainer, document.getElementById("footer"));

    var container = document.createElement("div");
    container.id = "tilesContainer";
    container.style.display = "inline-block";
    mainContainer.appendChild(container);

    var factor = zoomLevel / 100;
    var containerWidth = (((regularTile[0] * 4) + rightTile[0]) * factor);
    container.style.width = "" + containerWidth + "px";
    container.style.margin = "0 auto";

    if (containerWidth > w) {
        var leftMargin = Math.round((containerWidth - w) / 2);
        window.scroll(leftMargin, 0);
    } else container.style.margin = "0 auto";

    var topPad = document.createElement("div");
    topPad.id = "topPad";
    topPad.style.height = "50px";
    container.appendChild(topPad);

    var statusDiv = document.createElement("div");
    statusDiv.id = "statusDiv";
    statusDiv.className = "status";    
    var statusSpan = document.createElement("span");
    statusSpan.id = "statustxt";
    var statusTxt = document.createTextNode("Ritam broj " + numbers[issue][2] + ", strana " + page + " (" + zoomLevel + "%)");
    statusSpan.appendChild(statusTxt);
    statusDiv.appendChild(statusSpan);
    mainContainer.appendChild(statusDiv);

    var navPanel = document.createElement("div");
    navPanel.className = "navpanel";
    var navigation = document.createElement("div");
    navigation.id = "navigation";
    navigation.appendChild(navPanel);
    container.appendChild(navigation);

    var homeButton = createButton(navPanel, "home", "bnav", "assets/home.png", 32, 32);
    homeButton.onclick = function () {
        window.scroll(0, yearsScroll);
        showYears();
    };

    var zoomOutButton = createButton(navPanel, "zoomout", "bnav", "assets/minus.png", 32, 32);
    zoomOutButton.onclick = function () { zoom(-1); };

    var zoomInButton = createButton(navPanel, "zoomin", "bnav", "assets/plus.png", 32, 32);
    zoomInButton.onclick = function () { zoom(1); };

    var prevButton = createButton(navPanel, "prev", "bnav", "assets/prev.png", 32, 32);
    if (page > numbers[issue][0]) {
        prevButton.onclick = function () { window.scroll(0, 0); prev(); };
    } else prevButton.className = "bnavdisabled";

    var selectWrapper = document.createElement("div");
    selectWrapper.className = "navselectwrapper";
    var pageSelect = document.createElement("select");
    pageSelect.id = "pageselect";
    pageSelect.className = "navselect";
    pageSelect.onchange = function () { window.scroll(0, 0); jump(); };
    selectWrapper.appendChild(pageSelect);
    navPanel.appendChild(selectWrapper);

    for (var i=numbers[issue][0]; i <= numbers[issue][1]; i++) {
        var opt = document.createElement("option");
        opt.value = i;
        opt.text = "" + i + "";
        pageSelect.add(opt, null);
        if (i == page) opt.selected = true;
    }

    var nextButton = createButton(navPanel, "next", "bnav", "assets/next.png", 32, 32);
    if (page < numbers[issue][1]) { 
        nextButton.onclick = function () { window.scroll(0, 0); next(); };
    } else nextButton.className = "bnavdisabled";

    for (var v = 0; v <= 6; v++) {
        var rowDiv = document.createElement("div");
        rowDiv.id = "divrow";
        container.appendChild(rowDiv);
        for (var h = 0; h <= 4; h++) {
            var tileImg = document.createElement("img");
            tileImg.src = "/ritam/images/" + issue + "/" + page + "/2_" + h + "_" + v + ".jpg";
            tileImg.id = "tile_" + (v*5+h+1);
            tileImg.className = 'tile';
            if ((h == 4) && (v <= 5)) {
                tileImg.width  = rightTile[0] * factor;
                tileImg.height = rightTile[1] * factor;
            } else if ((h == 4) && (v == 6)) {
                tileImg.width  = cornerTile[0] * factor;
                tileImg.height = cornerTile[1] * factor;
            } else if ((h < 4) && (v == 6)) {
                tileImg.width  = bottomTile[0] * factor;
                tileImg.height = bottomTile[1] * factor;
            } else {
                tileImg.width  = regularTile[0] * factor;
                tileImg.height = regularTile[1] * factor;
            }
            tileImg.onload = function () {
                // add items count
            }
            rowDiv.appendChild(tileImg);
        }
        var clrDiv = document.createElement("div");
        clrDiv.className = "clr";
        container.appendChild(clrDiv);
    }
}

function totalPages() {
    var pages = 0;
    for (i=0; i < numbers.length; i++) {
        pages += numbers[i][1];
    }
    return pages;
}
